#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
(($# == 0)) || { kali_die 'backup accepts no arguments.'; exit 2; }
kali_load_config
umask 077
kali_prepare_user_dirs
kali_require_vm_stopped ""
DISK="$(kali_disk_path)"
kali_validate_qcow2 "$DISK"
"$(kali_qemu_img_binary)" check -f qcow2 -- "$DISK"
DISK_SIZE_BYTES="$(du -B1 -- "$DISK" | awk '{print $1}')"
[[ "$DISK_SIZE_BYTES" =~ ^[0-9]+$ ]] || { kali_die 'Could not determine the disk allocation size.'; exit 1; }
PARENT="$(dirname -- "$DISK")"
FREE_BYTES="$(df -PB1 -- "$PARENT" | awk 'NR==2 {print $4}')"
REQUIRED_BYTES=$((DISK_SIZE_BYTES + 67108864))
(( FREE_BYTES >= REQUIRED_BYTES )) || { kali_die 'Insufficient free space for a safety backup (allocated disk size plus 64 MiB required).'; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="${DISK}.backup-${STAMP}-$$"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { kali_die "Backup path already exists: $OUTPUT"; exit 1; }
TEMP="$(mktemp --tmpdir="$PARENT" ".$(basename -- "$OUTPUT").tmp.XXXXXXXX")"
cleanup() {
  if [[ -n "${TEMP:-}" && -e "$TEMP" && ! -L "$TEMP" ]]; then rm -f -- "$TEMP"; fi
}
trap cleanup EXIT
cp --reflink=auto --sparse=always --preserve=mode,timestamps -- "$DISK" "$TEMP"
chmod 600 -- "$TEMP"
"$(kali_qemu_img_binary)" check -f qcow2 -- "$TEMP"
ln -- "$TEMP" "$OUTPUT" || { kali_die 'Could not publish the backup without replacing an existing file.'; exit 1; }
rm -- "$TEMP"
TEMP=""
printf 'Created verified private backup: %s\nNo source disk or earlier backup was removed.\n' "$OUTPUT"
