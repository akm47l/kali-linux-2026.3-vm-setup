#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
if [[ "${1:-}" == --list || $# == 0 ]]; then exec "$SCRIPT_DIR/snapshot-kali.sh" list; fi
(($# == 1)) || { kali_die 'Usage: restore SNAPSHOT_NAME'; exit 2; }
NAME="$1"
[[ "$NAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { kali_die 'Snapshot name must use 1-64 letters, digits, dots, underscores, or hyphens.'; exit 2; }
kali_load_config
umask 077
kali_prepare_user_dirs
kali_require_vm_stopped
DISK="$(kali_disk_path)"
kali_validate_qcow2 "$DISK"
"$(kali_qemu_img_binary)" check -f qcow2 -- "$DISK"
"$(kali_qemu_img_binary)" snapshot -l "$DISK" | awk -v name="$NAME" '$2 == name {found=1} END {exit !found}' || { kali_die "Snapshot '$NAME' was not found in this QCOW2 disk."; exit 1; }
[[ -t 0 ]] || { kali_die 'Restore requires an interactive terminal so you can confirm the data change.'; exit 1; }
printf 'Restoring %s changes the active disk state. A byte-for-byte backup will be created first.\n' "$NAME"
printf 'Type exactly: RESTORE %s\n> ' "$NAME"
IFS= read -r ANSWER || true
[[ "$ANSWER" == "RESTORE $NAME" ]] || { printf 'Restore cancelled; no disk or backup was changed.\n'; exit 0; }
BACKUP_OUTPUT="$("$SCRIPT_DIR/backup-kali.sh")"
printf '%s\n' "$BACKUP_OUTPUT"
"$(kali_qemu_img_binary)" snapshot -a "$NAME" "$DISK"
"$(kali_qemu_img_binary)" check -f qcow2 -- "$DISK"
printf 'Restored snapshot %s; the pre-restore backup was retained.\n' "$NAME"
