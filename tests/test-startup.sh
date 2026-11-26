#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! command -v qemu-img >/dev/null 2>&1; then
  printf 'SKIP: qemu-system-x86_64 or qemu-img is not installed\n'
  exit 0
fi
TEMP="$(mktemp -d)"
chmod 700 "$TEMP"
LOCK_HOLDER_PID=""
START_PID=""
cleanup() {
  if [[ -n "$LOCK_HOLDER_PID" ]]; then
    kill "$LOCK_HOLDER_PID" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
  fi
  HOME="$TEMP/home" XDG_CONFIG_HOME="$TEMP/config-home" XDG_DATA_HOME="$TEMP/data-home" XDG_RUNTIME_DIR="$TEMP/runtime" KALI_CONFIG="$TEMP/config.conf" "$ROOT/scripts/stop-kali.sh" --force >/dev/null 2>&1 || true
  if [[ -n "$START_PID" ]]; then wait "$START_PID" 2>/dev/null || true; fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT
mkdir -m 700 "$TEMP/home" "$TEMP/config-home" "$TEMP/data-home" "$TEMP/runtime"
mkdir -m 700 "$TEMP/config-home/kali-virtual-security-lab" "$TEMP/data-home/kali-virtual-security-lab"
printf 'pass1234' > "$TEMP/config-home/kali-virtual-security-lab/vnc-password.txt"
chmod 600 "$TEMP/config-home/kali-virtual-security-lab/vnc-password.txt"
DISK="$TEMP/data-home/kali-virtual-security-lab/test.qcow2"
"$(command -v qemu-img)" create -q -f qcow2 "$DISK" 64M
chmod 600 "$DISK"
cat > "$TEMP/config.conf" <<'EOF'
VM_NAME=integration-test
DISK_PATH=test.qcow2
VNC_PASSWORD_FILE=vnc-password.txt
MEMORY=128M
CPU_CORES=1
ACCELERATION=tcg
NETWORK_MODE=OFFLINE
SSH_HOST_PORT=auto
VNC_DISPLAY=auto
DISK_SIZE=64M
INSTALLER_RELEASE=2026.3
SHUTDOWN_TIMEOUT=2
EOF
export HOME="$TEMP/home" XDG_CONFIG_HOME="$TEMP/config-home" XDG_DATA_HOME="$TEMP/data-home" XDG_RUNTIME_DIR="$TEMP/runtime" KALI_CONFIG="$TEMP/config.conf"

"$ROOT/scripts/snapshot-kali.sh" create before-live >/dev/null
(
  # shellcheck source=../scripts/lib/common.sh
  source "$ROOT/scripts/lib/common.sh"
  kali_load_config
  umask 077
  kali_prepare_user_dirs
  kali_acquire_vm_lock
  : > "$TEMP/lock-ready"
  sleep 2
) &
# shellcheck disable=SC2031 # Bash reports the PID of the background job in this parent shell.
LOCK_HOLDER_PID=$!
for _ in $(seq 1 50); do
  [[ -f "$TEMP/lock-ready" ]] && break
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || { printf 'FAIL: shared lock holder exited early\n' >&2; exit 1; }
  sleep 0.1
done
[[ -f "$TEMP/lock-ready" ]] || { printf 'FAIL: shared lock holder did not become ready\n' >&2; exit 1; }
if "$ROOT/scripts/start-kali.sh" > "$TEMP/start-blocked.log" 2>&1; then
  printf 'FAIL: start ignored a disk operation holding the shared lock\n' >&2; exit 1
fi
grep -q 'A VM start or disk operation is already in progress' "$TEMP/start-blocked.log" || { cat "$TEMP/start-blocked.log" >&2; printf 'FAIL: start failed for a reason other than the shared lock\n' >&2; exit 1; }
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""

"$ROOT/scripts/start-kali.sh" > "$TEMP/start.log" 2>&1 &
# shellcheck disable=SC2031 # Bash reports the PID of the background job in this parent shell.
START_PID=$!
READY=0
for _ in $(seq 1 120); do
  if grep -q 'VNC is bound only' "$TEMP/start.log" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$START_PID" 2>/dev/null; then cat "$TEMP/start.log" >&2; printf 'FAIL: QEMU launcher exited before QMP startup\n' >&2; exit 1; fi
  sleep 0.1
done
(( READY == 1 )) || { cat "$TEMP/start.log" >&2; printf 'FAIL: QEMU did not become ready\n' >&2; exit 1; }
SESSION_DIR="$(find "$TEMP/runtime/kali-virtual-security-lab/sessions" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print -quit)"
[[ -n "$SESSION_DIR" ]] || { printf 'FAIL: private session directory missing\n' >&2; exit 1; }
[[ "$(stat -c '%a' "$SESSION_DIR")" == 700 ]] || { printf 'FAIL: session directory is not mode 700\n' >&2; exit 1; }
QEMU_PID="$(cat "$SESSION_DIR/qemu.pid")"
LOCK_FILE="$TEMP/runtime/kali-virtual-security-lab/vm.lock"
LOCK_FD_PATH="$(readlink -f -- "/proc/$QEMU_PID/fd/9" 2>/dev/null || true)"
[[ "$LOCK_FD_PATH" == "$(readlink -f -- "$LOCK_FILE")" ]] || { printf 'FAIL: QEMU did not inherit vm.lock on FD 9\n' >&2; exit 1; }
[[ -S "$SESSION_DIR/qmp.sock" ]] || { printf 'FAIL: QMP socket missing\n' >&2; exit 1; }
QMP_MODE="$(stat -c '%a' "$SESSION_DIR/qmp.sock")"
(( (8#$QMP_MODE & 077) == 0 )) || { printf 'FAIL: QMP socket permissions are not private\n' >&2; exit 1; }
if tr '\0' '\n' < "/proc/$(cat "$SESSION_DIR/qemu.pid")/cmdline" | grep -Fq 'pass1234'; then
  printf 'FAIL: VNC password appeared in QEMU command line\n' >&2; exit 1
fi

expect_lock_block() {
  local label="$1"
  shift
  if "$@" > "$TEMP/$label.log" 2>&1; then
    printf 'FAIL: %s proceeded while QEMU held the shared lock\n' "$label" >&2; exit 1
  fi
  grep -q 'A VM start or disk operation is already in progress' "$TEMP/$label.log" || { cat "$TEMP/$label.log" >&2; printf 'FAIL: %s was blocked for an unexpected reason\n' "$label" >&2; exit 1; }
}
expect_lock_block backup "$ROOT/scripts/backup-kali.sh"
expect_lock_block snapshot "$ROOT/scripts/snapshot-kali.sh" create during-live-vm
expect_lock_block restore "$ROOT/scripts/restore-kali.sh" before-live
expect_lock_block create-disk "$ROOT/scripts/create-disk.sh" --size 64M --output extra.qcow2
"$ROOT/security/permissions-check.sh" > "$TEMP/permissions.log"
grep -q 'SKIP QCOW2 format check while the shared lock is held' "$TEMP/permissions.log" || { cat "$TEMP/permissions.log" >&2; printf 'FAIL: permissions check did not skip qemu-img while locked\n' >&2; exit 1; }
"$ROOT/scripts/status-kali.sh" > "$TEMP/status.log"
grep -q '"status"' "$TEMP/status.log" || { cat "$TEMP/status.log" >&2; printf 'FAIL: QMP status was not queried\n' >&2; exit 1; }
"$ROOT/scripts/stop-kali.sh" --force > "$TEMP/stop.log"
wait "$START_PID" || true
START_PID=""
[[ -z "$(find "$TEMP/runtime/kali-virtual-security-lab/sessions" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print -quit)" ]] || { printf 'FAIL: session runtime was not cleaned\n' >&2; exit 1; }

# Simulate the old launcher cleanup still holding vm.lock after stop reports no active QEMU.
(
  # shellcheck source=../scripts/lib/common.sh
  source "$ROOT/scripts/lib/common.sh"
  kali_load_config
  umask 077
  kali_prepare_user_dirs
  kali_acquire_vm_lock
  : > "$TEMP/restart-lock-ready"
  sleep 2
) &
# shellcheck disable=SC2031 # Bash reports the PID of the background job in this parent shell.
LOCK_HOLDER_PID=$!
for _ in $(seq 1 50); do
  [[ -f "$TEMP/restart-lock-ready" ]] && break
  kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || { printf 'FAIL: restart lock holder exited early\n' >&2; exit 1; }
  sleep 0.1
done
[[ -f "$TEMP/restart-lock-ready" ]] || { printf 'FAIL: restart lock holder did not become ready\n' >&2; exit 1; }
"$ROOT/scripts/restart-kali.sh" --force > "$TEMP/restart.log" 2>&1 &
# shellcheck disable=SC2031 # Bash reports the PID of the background job in this parent shell.
START_PID=$!
sleep 0.2
if grep -q 'A VM start or disk operation is already in progress' "$TEMP/restart.log"; then
  cat "$TEMP/restart.log" >&2
  printf 'FAIL: restart tried to start before the previous launcher released vm.lock\n' >&2
  exit 1
fi
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""
READY=0
for _ in $(seq 1 120); do
  if grep -q 'VNC is bound only' "$TEMP/restart.log" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$START_PID" 2>/dev/null; then cat "$TEMP/restart.log" >&2; printf 'FAIL: restart exited before the new QEMU became ready\n' >&2; exit 1; fi
  sleep 0.1
done
(( READY == 1 )) || { cat "$TEMP/restart.log" >&2; printf 'FAIL: restart did not launch QEMU after vm.lock was released\n' >&2; exit 1; }
SESSION_DIR="$(find "$TEMP/runtime/kali-virtual-security-lab/sessions" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print -quit)"
[[ -n "$SESSION_DIR" ]] || { printf 'FAIL: restarted session directory missing\n' >&2; exit 1; }
QEMU_PID="$(cat "$SESSION_DIR/qemu.pid")"
LOCK_FD_PATH="$(readlink -f -- "/proc/$QEMU_PID/fd/9" 2>/dev/null || true)"
[[ "$LOCK_FD_PATH" == "$(readlink -f -- "$LOCK_FILE")" ]] || { printf 'FAIL: restarted QEMU did not inherit vm.lock on FD 9\n' >&2; exit 1; }
"$ROOT/scripts/stop-kali.sh" --force > "$TEMP/restart-stop.log"
wait "$START_PID" || true
START_PID=""
[[ -z "$(find "$TEMP/runtime/kali-virtual-security-lab/sessions" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print -quit)" ]] || { printf 'FAIL: restarted session runtime was not cleaned\n' >&2; exit 1; }
printf 'PASS: confined per-user paths, mutual start/disk locking, QEMU TCG startup, restart lock handoff, QMP/VNC setup, blocked concurrent qemu-img operations, status, stop, and cleanup\n'
