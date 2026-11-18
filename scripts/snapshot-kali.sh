#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ACTION="${1:-list}"
if (($#)); then shift; fi
kali_load_config
umask 077
kali_prepare_user_dirs
kali_require_vm_stopped
DISK="$(kali_disk_path)"
kali_validate_qcow2 "$DISK"
case "$ACTION" in
  list)
    (($# == 0)) || { kali_die 'Usage: snapshot [list|create NAME]'; exit 2; }
    printf 'QCOW2 snapshots for this user and disk:\n'
    "$(kali_qemu_img_binary)" snapshot -l "$DISK"
    if [[ -f "$KALI_DATA_HOME/snapshots.tsv" && ! -L "$KALI_DATA_HOME/snapshots.tsv" ]]; then
      kali_validate_private_file "$KALI_DATA_HOME/snapshots.tsv"
      printf '\nPrivate creation log (UTC timestamp and snapshot name):\n'
      cat -- "$KALI_DATA_HOME/snapshots.tsv"
    fi
    ;;
  create)
    (($# == 1)) || { kali_die 'Usage: snapshot create NAME'; exit 2; }
    NAME="$1"
    [[ "$NAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { kali_die 'Snapshot name must use 1-64 letters, digits, dots, underscores, or hyphens.'; exit 2; }
    "$(kali_qemu_img_binary)" check -f qcow2 -- "$DISK"
    INDEX="$KALI_DATA_HOME/snapshots.tsv"
    if [[ -e "$INDEX" || -L "$INDEX" ]]; then
      kali_validate_private_file "$INDEX"
    else
      (set -o noclobber; : > "$INDEX") 2>/dev/null || { kali_die 'Could not safely create snapshot log.'; exit 1; }
      chmod 600 -- "$INDEX"
    fi
    if "$(kali_qemu_img_binary)" snapshot -l "$DISK" | awk -v name="$NAME" '$2 == name {found=1} END {exit !found}'; then
      kali_die "Snapshot '$NAME' already exists; choose another name."
      exit 1
    fi
    "$(kali_qemu_img_binary)" snapshot -c "$NAME" "$DISK"
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" >> "$INDEX"
    printf 'Snapshot %s created and recorded. It will not be removed automatically.\n' "$NAME"
    ;;
  *) kali_die 'Usage: snapshot [list|create NAME]'; exit 2 ;;
esac
