#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
FORCE=0
while (($#)); do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) printf 'Usage: %s [--force]\n' "$0"; exit 0 ;;
    *) kali_die "Unknown argument: $1"; exit 2 ;;
  esac
done
kali_load_config
kali_ensure_private_runtime
ACTIVE="$(kali_active_sessions)"
[[ -n "$ACTIVE" ]] || { printf 'No active VM session for Linux UID %s.\n' "$(id -u)"; exit 0; }
COUNT="$(printf '%s\n' "$ACTIVE" | awk 'NF {n++} END {print n+0}')"
(( COUNT == 1 )) || { kali_die 'More than one active VM is recorded for this user; refusing an ambiguous stop.'; exit 1; }
SESSION_DIR="${ACTIVE%%$'\t'*}"
PID="${ACTIVE#*$'\t'}"
QMP_SOCKET="$SESSION_DIR/qmp.sock"
kali_validate_socket "$QMP_SOCKET"
kali_pid_is_our_qemu "$PID" "$QMP_SOCKET" || { kali_die 'PID does not match the QEMU process and QMP socket in this session.'; exit 1; }
if (( FORCE )); then
  printf 'Force stop requested: the guest may not flush its filesystem.\n' >&2
  python3 "$SCRIPT_DIR/lib/qmp.py" quit "$QMP_SOCKET"
  TIMEOUT=15
else
  python3 "$SCRIPT_DIR/lib/qmp.py" powerdown "$QMP_SOCKET"
  TIMEOUT="$SHUTDOWN_TIMEOUT"
fi
for ((i = 0; i < TIMEOUT; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    printf 'QEMU stopped for Linux UID %s.\n' "$(id -u)"
    exit 0
  fi
  sleep 1
done
if (( FORCE )); then
  if kill -0 "$PID" 2>/dev/null && kali_pid_is_our_qemu "$PID" "$QMP_SOCKET"; then
    kill -TERM "$PID" 2>/dev/null || true
    for ((i = 0; i < 5; i++)); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
  fi
  if kill -0 "$PID" 2>/dev/null; then
    kali_die 'QEMU did not stop after the explicit force request; no unrelated process was signalled.'
    exit 1
  fi
  printf 'QEMU stopped after the explicit force request. Check the guest filesystem on next boot.\n'
  exit 0
fi
kali_die "The guest has not shut down after ${TIMEOUT}s. Shut it down inside Kali, or rerun './kali.sh stop --force' only if you accept an abrupt QEMU quit."
exit 1
