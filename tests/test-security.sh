#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TEMP="$(mktemp -d)"
chmod 700 "$TEMP"
trap 'rm -rf -- "$TEMP"' EXIT
umask 077
printf 'pass1234' > "$TEMP/password"
chmod 600 "$TEMP/password"
kali_validate_vnc_password_file "$TEMP/password" || fail 'short VNC password should be accepted'
printf 'password-too-long' > "$TEMP/password-long"
chmod 600 "$TEMP/password-long"
if kali_validate_vnc_password_file "$TEMP/password-long" >/dev/null 2>&1; then fail 'password longer than eight bytes must be rejected'; fi
printf 'short\n' > "$TEMP/password-line"
chmod 600 "$TEMP/password-line"
kali_validate_vnc_password_file "$TEMP/password-line" || fail 'one final line break should be accepted'
chmod 644 "$TEMP/password"
if kali_validate_vnc_password_file "$TEMP/password" >/dev/null 2>&1; then fail 'group/world-readable secret must be rejected'; fi
KALI_RUNTIME_DIR="$TEMP/runtime/kali-virtual-security-lab"
KALI_CONFIG_HOME="$TEMP/config/kali-virtual-security-lab"
KALI_DATA_HOME="$TEMP/data/kali-virtual-security-lab"
mkdir -p "$KALI_RUNTIME_DIR" "$KALI_CONFIG_HOME" "$KALI_DATA_HOME"
chmod 700 "$KALI_RUNTIME_DIR" "$KALI_CONFIG_HOME" "$KALI_DATA_HOME"
printf 'lock-target-must-not-change' > "$TEMP/outside-lock"
chmod 600 "$TEMP/outside-lock"
ln -s "$TEMP/outside-lock" "$KALI_RUNTIME_DIR/vm.lock"
if kali_acquire_vm_lock >/dev/null 2>&1; then fail 'symlink at the per-user VM lock path must be rejected'; fi
[[ "$(cat "$TEMP/outside-lock")" == lock-target-must-not-change ]] || fail 'rejected lock symlink target must remain untouched'
if grep -RIl -E --exclude-dir=.git --exclude=LICENSE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}' "$ROOT" >/dev/null; then
  fail 'repository contains a private key or common credential-token pattern'
fi
printf 'PASS: VNC password limits, secret-file permissions, lock symlink rejection, and repository secret markers\n'
