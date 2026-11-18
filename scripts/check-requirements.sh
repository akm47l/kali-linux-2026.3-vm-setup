#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
(($# == 0)) || { kali_die 'check accepts no arguments.'; exit 2; }
FAIL=0
check_command() {
  if command -v "$1" >/dev/null 2>&1; then printf 'OK: %s\n' "$1"; else printf 'MISSING: %s\n' "$1"; FAIL=1; fi
}
printf 'Kali Virtual Security Lab host check (Linux UID %s)\n' "$(id -u)"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'CPU cores available: %s\n' "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
check_command bash
check_command python3
check_command flock
check_command "$(kali_qemu_binary)"
check_command "$(kali_qemu_img_binary)"
if command -v "$(kali_qemu_binary)" >/dev/null 2>&1; then "$(kali_qemu_binary)" --version | head -1; fi
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  printf 'KVM: available and accessible\n'
else
  printf 'KVM: unavailable; auto mode will use TCG software emulation\n'
fi
if [[ -e /dev/kvm && ! -r /dev/kvm ]]; then printf 'KVM note: device exists but this user cannot read it\n'; fi
if [[ -e /dev/kvm && ! -w /dev/kvm ]]; then printf 'KVM note: device exists but this user cannot write it\n'; fi
if ! kali_load_config; then exit 1; fi
if ! kali_resolve_resources; then FAIL=1; else printf 'Resource profile %s: %s MiB RAM, %s vCPU(s)\n' "$PROFILE" "$RESOLVED_MEMORY_MIB" "$RESOLVED_CPUS"; fi
if ! kali_choose_accelerator; then FAIL=1; else printf 'Selected acceleration: %s\n' "$RESOLVED_ACCEL"; fi
if ! kali_resolve_ports; then FAIL=1; else printf 'Loopback ports (selected for this user): VNC %s, SSH %s\n' "$((5900 + RESOLVED_VNC_DISPLAY))" "$RESOLVED_SSH_HOST_PORT"; fi
DISK="$(kali_disk_path)"
if [[ -e "$DISK" ]]; then
  if kali_require_vm_stopped --quiet; then
    if kali_validate_qcow2 "$DISK"; then
      if "$(kali_qemu_img_binary)" check -f qcow2 -- "$DISK"; then
        printf 'OK: QCOW2 integrity check\n'
      else
        printf 'FAIL: QCOW2 integrity check\n'
        FAIL=1
      fi
    else
      FAIL=1
    fi
  else
    LOCK_RESULT=$?
    if (( LOCK_RESULT == 2 )); then
      printf 'SKIP: QCOW2 integrity check while this user has an active VM or disk operation\n'
    else
      FAIL=1
    fi
  fi
else
  printf 'INFO: no per-user disk yet (%s); ./kali.sh install creates a new one\n' "$DISK"
fi
PASSWORD_FILE="$(kali_password_path)"
if [[ -e "$PASSWORD_FILE" ]]; then
  if kali_validate_vnc_password_file "$PASSWORD_FILE"; then printf 'OK: private VNC password file (value not displayed)\n'; else FAIL=1; fi
else
  printf 'INFO: no VNC password yet; create %s before start/install\n' "$PASSWORD_FILE"
fi
for cmd in curl gpgv; do check_command "$cmd"; done
if (( FAIL )); then printf 'Result: failed checks; see messages above.\n' >&2; exit 1; fi
printf 'Result: available checks passed. A Kali guest boot was not attempted.\n'
