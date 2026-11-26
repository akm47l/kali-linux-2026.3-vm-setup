#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
(($# == 0)) || { kali_die 'status accepts no arguments.'; exit 2; }
kali_load_config
printf 'Linux UID: %s\n' "$(id -u)"
printf 'Private data: %s\nPrivate runtime: %s\n' "$KALI_DATA_HOME" "$KALI_RUNTIME_DIR"
ACTIVE="$(kali_active_sessions)"
if [[ -z "$ACTIVE" ]]; then
  printf 'State: stopped (no active VM for this user)\n'
  exit 0
fi
COUNT="$(printf '%s\n' "$ACTIVE" | awk 'NF {n++} END {print n+0}')"
printf 'Active session records: %s\n' "$COUNT"
while IFS=$'\t' read -r dir pid; do
  [[ -n "$dir" && -n "$pid" ]] || continue
  QMP_SOCKET="$dir/qmp.sock"
  printf 'PID: %s\n' "$pid"
  if kali_validate_socket "$QMP_SOCKET" >/dev/null 2>&1; then
    printf 'QMP: private socket verified\n'
    printf 'QEMU: '
    python3 "$SCRIPT_DIR/lib/qmp.py" status "$QMP_SOCKET" || printf 'status query failed\n'
  else
    printf 'QMP: socket permissions or ownership check failed\n'
  fi
  if [[ -r "$dir/metadata" && ! -L "$dir/metadata" ]]; then
    while IFS= read -r line; do
      case "$line" in uid=*|vm_name=*|acceleration=*|network_mode=*|memory_mib=*|cpu_cores=*|ssh_host_port=*|vnc_display=*|started_utc=*) printf '%s\n' "$line" ;; esac
    done < "$dir/metadata"
  fi
done <<< "$ACTIVE"
SESSIONS_DIR="$KALI_RUNTIME_DIR/sessions"
if [[ -d "$SESSIONS_DIR" ]]; then
  while IFS= read -r -d '' dir; do
    [[ -n "$(kali_session_pid "$dir" 2>/dev/null || true)" ]] && continue
    [[ -e "$dir" ]] && printf 'Notice: an incomplete/stale private session record exists at %s; it was not removed. Inspect it manually.\n' "$dir"
  done < <(find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print0 2>/dev/null)
fi
