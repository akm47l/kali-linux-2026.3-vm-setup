#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
(($# == 0)) || { kali_die 'permissions-check accepts no arguments.'; exit 2; }
kali_load_config
FAIL=0
for dir in "$KALI_CONFIG_HOME" "$KALI_DATA_HOME" "$KALI_RUNTIME_DIR"; do
  if [[ -e "$dir" ]]; then
    if kali_ensure_private_dir "$dir"; then printf 'OK: private directory %s\n' "$dir"; else FAIL=1; fi
  else
    printf 'INFO: not created yet: %s\n' "$dir"
  fi
done
DISK="$(kali_disk_path)"
if [[ -e "$DISK" ]]; then
  if kali_require_vm_stopped --quiet; then
    if kali_validate_qcow2 "$DISK"; then printf 'OK: private QCOW2 disk\n'; else FAIL=1; fi
  else
    LOCK_RESULT=$?
    if (( LOCK_RESULT == 2 )); then
      if kali_validate_private_file "$DISK"; then printf 'OK: private disk file; SKIP QCOW2 format check while the shared lock is held\n'; else FAIL=1; fi
    else FAIL=1; fi
  fi
else printf 'INFO: per-user disk does not exist yet\n'; fi
PASSWORD="$(kali_password_path)"
if [[ -e "$PASSWORD" ]]; then if kali_validate_vnc_password_file "$PASSWORD"; then printf 'OK: private VNC password file (value not displayed)\n'; else FAIL=1; fi; else printf 'INFO: VNC password file does not exist yet\n'; fi
(( FAIL == 0 )) || exit 1
printf 'Result: no permission checks failed.\n'
