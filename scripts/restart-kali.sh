#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
FORCE_ARGS=()
if [[ "${1:-}" == --force ]]; then FORCE_ARGS=(--force); shift; fi
(($# == 0)) || { printf 'Usage: %s [--force]\n' "$0" >&2; exit 2; }
kali_load_config
umask 077
kali_prepare_user_dirs
"$SCRIPT_DIR/stop-kali.sh" "${FORCE_ARGS[@]}"

# stop may observe QEMU exit before start-kali.sh finishes cleaning its session and releases FD 9.
for ((attempt = 0; attempt < 150; attempt++)); do
  if kali_acquire_vm_lock --quiet; then
    # Carry the acquired lock into start-kali.sh so another disk operation cannot win the gap.
    exec "$SCRIPT_DIR/start-kali.sh"
  else
    LOCK_RESULT=$?
    if (( LOCK_RESULT != 2 )); then exit "$LOCK_RESULT"; fi
  fi
  sleep 0.1
done
kali_die 'Timed out waiting for the previous VM or disk operation to release vm.lock; retry restart.'
exit 1
