#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! command -v qemu-img >/dev/null 2>&1; then
  printf 'SKIP: qemu-system-x86_64 or qemu-img is not installed\n'
  exit 0
fi
TEMP="$(mktemp -d)"
chmod 700 "$TEMP"
cleanup() {
  HOME="$TEMP/home" XDG_CONFIG_HOME="$TEMP/xdg-config" XDG_DATA_HOME="$TEMP/xdg-data" XDG_RUNTIME_DIR="$TEMP/xdg-runtime" KALI_CONFIG="$TEMP/config.conf" "$ROOT/scripts/stop-kali.sh" --force >/dev/null 2>&1 || true
  if [[ -n "${START_PID:-}" ]]; then wait "$START_PID" 2>/dev/null || true; fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT
mkdir -m 700 "$TEMP/home" "$TEMP/config-home" "$TEMP/data-home" "$TEMP/runtime"
printf 'pass1234' > "$TEMP/password"
chmod 600 "$TEMP/password"
"$(command -v qemu-img)" create -q -f qcow2 "$TEMP/test.qcow2" 64M
chmod 600 "$TEMP/test.qcow2"
cat > "$TEMP/config.conf" <<EOF
VM_NAME=integration-test
DISK_PATH=$TEMP/test.qcow2
VNC_PASSWORD_FILE=$TEMP/password
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
export HOME="$TEMP/home" XDG_CONFIG_HOME="$TEMP/xdg-config" XDG_DATA_HOME="$TEMP/xdg-data" XDG_RUNTIME_DIR="$TEMP/runtime" KALI_CONFIG="$TEMP/config.conf"
"$ROOT/scripts/start-kali.sh" > "$TEMP/start.log" 2>&1 &
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
[[ -S "$SESSION_DIR/qmp.sock" ]] || { printf 'FAIL: QMP socket missing\n' >&2; exit 1; }
QMP_MODE="$(stat -c '%a' "$SESSION_DIR/qmp.sock")"
(( (8#$QMP_MODE & 077) == 0 )) || { printf 'FAIL: QMP socket permissions are not private\n' >&2; exit 1; }
if tr '\0' '\n' < "/proc/$(cat "$SESSION_DIR/qemu.pid")/cmdline" | grep -Fq 'pass1234'; then
  printf 'FAIL: VNC password appeared in QEMU command line\n' >&2; exit 1
fi
"$ROOT/scripts/status-kali.sh" > "$TEMP/status.log"
grep -q '"status"' "$TEMP/status.log" || { cat "$TEMP/status.log" >&2; printf 'FAIL: QMP status was not queried\n' >&2; exit 1; }
"$ROOT/scripts/stop-kali.sh" --force > "$TEMP/stop.log"
wait "$START_PID" || true
START_PID=""
[[ -z "$(find "$TEMP/runtime/kali-virtual-security-lab/sessions" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print -quit)" ]] || { printf 'FAIL: session runtime was not cleaned\n' >&2; exit 1; }
printf 'PASS: QEMU TCG startup, QMP/VNC setup, per-user runtime permissions, status, stop, and cleanup\n'
