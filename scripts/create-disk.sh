#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
SIZE=""
OUTPUT=""
while (($#)); do
  case "$1" in
    --size) (($# >= 2)) || { kali_die '--size requires a value such as 80G.'; exit 2; }; SIZE="$2"; shift 2 ;;
    --output) (($# >= 2)) || { kali_die '--output requires a filename.'; exit 2; }; OUTPUT="$2"; shift 2 ;;
    -h|--help) printf 'Usage: %s [--size 80G] [--output FILENAME]\n' "$0"; exit 0 ;;
    *) kali_die "Unknown argument: $1"; exit 2 ;;
  esac
done
kali_load_config
umask 077
kali_prepare_user_dirs
kali_require_vm_stopped ""
[[ -n "$SIZE" ]] || SIZE="$DISK_SIZE"
[[ -n "$OUTPUT" ]] || OUTPUT="$DISK_PATH"
[[ "$OUTPUT" =~ ^[A-Za-z0-9_.-]{1,128}$ && "$OUTPUT" != . && "$OUTPUT" != .. ]] || { kali_die "--output must be a simple filename inside this user's private data directory."; exit 2; }
OUTPUT="$KALI_DATA_HOME/$OUTPUT"
[[ "$SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || { kali_die 'Disk size must be a positive integer followed by K, M, or G.'; exit 2; }
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then kali_die "Refusing to replace an existing path: $OUTPUT"; exit 1; fi
SIZE_BYTES="$(kali_size_bytes "$SIZE")" || { kali_die "Invalid or too large disk size: $SIZE"; exit 2; }
kali_check_disk_free "$OUTPUT" "$SIZE_BYTES"
PARENT="$(dirname -- "$OUTPUT")"
BASE="$(basename -- "$OUTPUT")"
TEMP="$(mktemp --tmpdir="$PARENT" ".${BASE}.tmp.XXXXXXXX")"
cleanup() {
  if [[ -n "${TEMP:-}" && -e "$TEMP" && ! -L "$TEMP" ]]; then rm -f -- "$TEMP"; fi
}
trap cleanup EXIT
rm -- "$TEMP"
"$(kali_qemu_img_binary)" create -f qcow2 -o compat=1.1,cluster_size=64k "$TEMP" "$SIZE"
chmod 600 -- "$TEMP"
"$(kali_qemu_img_binary)" check -f qcow2 -- "$TEMP"
ln -- "$TEMP" "$OUTPUT" || { kali_die "Could not publish the new disk without replacing an existing file: $OUTPUT"; exit 1; }
rm -- "$TEMP"
TEMP=""
printf 'Created a new sparse QCOW2 disk (%s virtual capacity) at %s. Existing disks were not changed.\n' "$SIZE" "$OUTPUT"
