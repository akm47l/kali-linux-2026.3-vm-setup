#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

INSTALLER_ISO=""
while (($#)); do
  case "$1" in
    --installer)
      (($# >= 2)) || { kali_die '--installer requires a verified ISO path.'; exit 2; }
      INSTALLER_ISO="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--installer VERIFIED_ISO]\n' "$0"
      exit 0
      ;;
    *) kali_die "Unknown argument: $1"; exit 2 ;;
  esac
done

kali_load_config
umask 077
kali_prepare_user_dirs
QEMU="$(kali_qemu_binary)"
QEMU_IMG="$(kali_qemu_img_binary)"
command -v "$QEMU" >/dev/null 2>&1 || { kali_die "QEMU executable not found: $QEMU"; exit 1; }
command -v "$QEMU_IMG" >/dev/null 2>&1 || { kali_die "qemu-img executable not found: $QEMU_IMG"; exit 1; }
command -v flock >/dev/null 2>&1 || { kali_die 'flock is required.'; exit 1; }
command -v python3 >/dev/null 2>&1 || { kali_die 'Python 3 is required.'; exit 1; }

DISK="$(kali_disk_path)"
PASSWORD_FILE="$(kali_password_path)"
kali_validate_qcow2 "$DISK"
kali_validate_vnc_password_file "$PASSWORD_FILE"
if [[ -n "$INSTALLER_ISO" ]]; then
  [[ -f "$INSTALLER_ISO" && ! -L "$INSTALLER_ISO" && -r "$INSTALLER_ISO" ]] || { kali_die "Installer ISO is not a readable regular file: $INSTALLER_ISO"; exit 1; }
  kali_path_owner_is_current "$INSTALLER_ISO" || { kali_die 'Installer ISO must be owned by the current user.'; exit 1; }
fi
kali_resolve_resources
kali_choose_accelerator
kali_resolve_ports
kali_ensure_private_runtime

LOCK_FILE="$KALI_RUNTIME_DIR/vm.lock"
[[ ! -L "$LOCK_FILE" ]] || { kali_die 'Refusing a symlink at the per-user VM lock path.'; exit 1; }
if [[ -e "$LOCK_FILE" ]]; then
  kali_validate_private_file "$LOCK_FILE" || exit 1
else
  (set -o noclobber; : > "$LOCK_FILE") 2>/dev/null || { kali_die 'Could not safely create the per-user VM lock.'; exit 1; }
  chmod 600 -- "$LOCK_FILE"
fi
exec 9>>"$LOCK_FILE"
flock -n 9 || { kali_die 'A VM session is already being started or managed by this user.'; exit 1; }
ACTIVE="$(kali_active_sessions)"
[[ -z "$ACTIVE" ]] || { kali_die 'This user already has an active VM session; run ./kali.sh status.'; exit 1; }

SESSION_DIR="$KALI_RUNTIME_DIR/sessions/session-$(id -u)-$BASHPID"
mkdir -m 700 -- "$SESSION_DIR" || { kali_die "Could not create a private session directory: $SESSION_DIR"; exit 1; }
QMP_SOCKET="$SESSION_DIR/qmp.sock"
QEMU_PID=""
CHILD_PID=""
CLEANING=0
cleanup() {
  local result=$? i pid
  (( CLEANING == 0 )) || return "$result"
  CLEANING=1
  trap - EXIT INT TERM
  pid="$(kali_session_pid "$SESSION_DIR" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kali_pid_is_our_qemu "$pid" "$QMP_SOCKET"; then
    if [[ -S "$QMP_SOCKET" ]]; then
      python3 "$SCRIPT_DIR/lib/qmp.py" quit "$QMP_SOCKET" >/dev/null 2>&1 || true
    fi
    for ((i = 0; i < 5; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null && kali_pid_is_our_qemu "$pid" "$QMP_SOCKET"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  elif [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    # Before QEMU writes its PID file, the child ID is known from this process.
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  if [[ -n "$CHILD_PID" ]]; then wait "$CHILD_PID" 2>/dev/null || true; fi
  if [[ -d "$SESSION_DIR" && ! -L "$SESSION_DIR" && "$SESSION_DIR" == "$KALI_RUNTIME_DIR/sessions/session-$(id -u)-$BASHPID" ]]; then
    rm -rf -- "$SESSION_DIR"
  fi
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

NETWORK_ARGS=()
kali_build_network_args "$NETWORK_MODE" NETWORK_ARGS "$SESSION_DIR/isolated-net.sock"
QEMU_ARGS=(
  -name "$VM_NAME"
  -machine q35
  -accel "$RESOLVED_ACCEL"
  -cpu "$([[ "$RESOLVED_ACCEL" == kvm ]] && printf host || printf max)"
  -smp "$RESOLVED_CPUS"
  -m "${RESOLVED_MEMORY_MIB}M"
  -drive "file=$DISK,if=virtio,format=qcow2,cache=writeback"
  -vnc "127.0.0.1:${RESOLVED_VNC_DISPLAY},password=on"
  -qmp "unix:$QMP_SOCKET,server=on,wait=off"
  -display none
  -monitor none
  -serial "file:$SESSION_DIR/serial.log"
  -pidfile "$SESSION_DIR/qemu.pid"
  "${NETWORK_ARGS[@]}"
)
if [[ -n "$INSTALLER_ISO" ]]; then
  QEMU_ARGS+=(-cdrom "$INSTALLER_ISO" -boot 'order=d,menu=on')
else
  QEMU_ARGS+=(-boot order=c)
fi
kali_record_session_metadata "$SESSION_DIR" "$RESOLVED_ACCEL" "$NETWORK_MODE" "$RESOLVED_MEMORY_MIB" "$RESOLVED_CPUS" "$RESOLVED_SSH_HOST_PORT" "$RESOLVED_VNC_DISPLAY"
chmod 600 -- "$SESSION_DIR/metadata"
printf 'Starting %s for Linux UID %s: %s MiB RAM, %s vCPU(s), %s, network %s.\n' \
  "$VM_NAME" "$(id -u)" "$RESOLVED_MEMORY_MIB" "$RESOLVED_CPUS" "$RESOLVED_ACCEL" "$NETWORK_MODE"
"$QEMU" "${QEMU_ARGS[@]}" >"$SESSION_DIR/qemu.log" 2>&1 &
CHILD_PID=$!

for ((i = 0; i < 100; i++)); do
  if [[ -S "$QMP_SOCKET" && -s "$SESSION_DIR/qemu.pid" ]]; then break; fi
  if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    kali_die "QEMU exited during startup; inspect the private log: $SESSION_DIR/qemu.log"
    exit 1
  fi
  sleep 0.1
done
[[ -S "$QMP_SOCKET" && -s "$SESSION_DIR/qemu.pid" ]] || { kali_die "QEMU QMP socket did not become ready; inspect $SESSION_DIR/qemu.log"; exit 1; }
QEMU_PID="$(kali_session_pid "$SESSION_DIR" 2>/dev/null || true)"
[[ -n "$QEMU_PID" && "$QEMU_PID" == "$CHILD_PID" ]] || { kali_die 'QEMU PID file did not match the process started by this session.'; exit 1; }
kali_pid_is_our_qemu "$QEMU_PID" "$QMP_SOCKET" || { kali_die 'The QMP socket and PID file are not owned by the QEMU process started here.'; exit 1; }
kali_validate_socket "$QMP_SOCKET"
python3 "$SCRIPT_DIR/lib/qmp.py" set-password "$QMP_SOCKET" "$PASSWORD_FILE"
printf 'VNC is bound only to 127.0.0.1:%s. For remote access, use an SSH tunnel; classic VNC uses only 8 password bytes.\n' "$((5900 + RESOLVED_VNC_DISPLAY))"
if [[ "$NETWORK_MODE" == NAT ]]; then
  printf 'Guest SSH is forwarded only to 127.0.0.1:%s.\n' "$RESOLVED_SSH_HOST_PORT"
fi
printf 'Session state is private to UID %s; stop with ./kali.sh stop.\n' "$(id -u)"
wait "$CHILD_PID"
