#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
(($# == 0)) || { kali_die 'install accepts no arguments; configure the disk path, size, and release in your per-user config.'; exit 2; }
kali_load_config
umask 077
kali_prepare_user_dirs
DISK="$(kali_disk_path)"
if [[ -e "$DISK" || -L "$DISK" ]]; then
  kali_die "Install will not replace an existing disk. Change DISK_PATH in your private config to create a separate blank disk: $DISK"
  exit 1
fi
PASSWORD_FILE="$(kali_password_path)"
kali_validate_vnc_password_file "$PASSWORD_FILE"
for cmd in curl gpg gpgv sha256sum qemu-system-x86_64 qemu-img; do command -v "$cmd" >/dev/null 2>&1 || { kali_die "Required installation tool is missing: $cmd"; exit 1; }; done
"$SCRIPT_DIR/download-verify.sh"
ISO="$KALI_DATA_HOME/installer/kali-linux-${INSTALLER_RELEASE}-installer-amd64.iso"
[[ -f "$ISO" ]] || { kali_die 'Verified installer ISO is missing after download verification.'; exit 1; }
# The configured size is a maximum sparse capacity; available host space is checked before creation.
"$SCRIPT_DIR/../scripts/create-disk.sh" --size "$DISK_SIZE" --output "$DISK"
printf '\nStarting the interactive installer. Use the VNC viewer at 127.0.0.1 on the selected port shown below; no guest is preinstalled.\n'
"$SCRIPT_DIR/../scripts/start-kali.sh" --installer "$ISO"
printf "\nInstaller session ended. The ISO and new disk remain in this user's private data directory; no image is uploaded to GitHub.\n"
printf 'After Kali has completed installation and shut down, run ./kali.sh start.\n'
