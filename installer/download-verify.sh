#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/../scripts/lib/common.sh"
(($# == 0)) || { kali_die 'download-verify accepts no arguments; configure INSTALLER_RELEASE instead.'; exit 2; }
kali_load_config
umask 077
kali_prepare_user_dirs
for cmd in curl gpg gpgv sha256sum awk; do command -v "$cmd" >/dev/null 2>&1 || { kali_die "Required installer verification tool is missing: $cmd"; exit 1; }; done
RELEASE="$INSTALLER_RELEASE"
FILENAME="kali-linux-${RELEASE}-installer-amd64.iso"
BASE_URL="https://cdimage.kali.org/kali-${RELEASE}"
OUTPUT_DIR="$KALI_DATA_HOME/installer"
kali_ensure_private_dir "$OUTPUT_DIR"
OUTPUT_ISO="$OUTPUT_DIR/$FILENAME"
WORK="$(mktemp -d --tmpdir="$OUTPUT_DIR" .verify.XXXXXXXX)"
chmod 700 -- "$WORK"
cleanup() {
  if [[ -n "${WORK:-}" && -d "$WORK" && ! -L "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
  --retry 3 --retry-delay 2 --output "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS"
curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
  --retry 3 --retry-delay 2 --output "$WORK/SHA256SUMS.gpg" "$BASE_URL/SHA256SUMS.gpg"
curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
  --retry 3 --retry-delay 2 --output "$WORK/archive-key.asc" 'https://archive.kali.org/archive-key.asc'

GNUPGHOME="$WORK/gnupg"
mkdir -m 700 -- "$GNUPGHOME"
EXPECTED_KEY='827C8569F2518CC677FECA1AED65462EC8D5E4C5'
KEY_FINGERPRINTS="$(gpg --batch --no-options --homedir "$GNUPGHOME" --with-colons --with-fingerprint --show-keys "$WORK/archive-key.asc" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10)}')"
printf '%s\n' "$KEY_FINGERPRINTS" | grep -Fxq "$EXPECTED_KEY" || { kali_die 'The downloaded Kali key did not contain the independently pinned official signing-key fingerprint.'; exit 1; }
gpg --batch --no-options --homedir "$GNUPGHOME" --import "$WORK/archive-key.asc" >/dev/null 2>&1
gpg --batch --no-options --homedir "$GNUPGHOME" --export "$EXPECTED_KEY" > "$WORK/kali-keyring.gpg"
[[ -s "$WORK/kali-keyring.gpg" ]] || { kali_die 'Could not create the pinned Kali public keyring.'; exit 1; }
if ! gpgv --status-fd=1 --keyring "$WORK/kali-keyring.gpg" "$WORK/SHA256SUMS.gpg" "$WORK/SHA256SUMS" > "$WORK/gpg-status" 2> "$WORK/gpg-diagnostic"; then
  kali_die 'The official Kali checksum manifest signature did not verify; no ISO was accepted.'
  exit 1
fi
awk -v fingerprint="$EXPECTED_KEY" 'toupper($1) == "[GNUPG:]" && $2 == "VALIDSIG" && (toupper($3) == fingerprint || toupper($12) == fingerprint) {ok=1} END {exit !ok}' "$WORK/gpg-status" || { kali_die 'Checksum signature was valid but was not made by the pinned Kali signing key.'; exit 1; }
EXPECTED_SHA="$(awk -v name="$FILENAME" '($2 == name || $2 == "*" name) {count++; hash=tolower($1)} END {if (count != 1 || hash !~ /^[0-9a-f]{64}$/) exit 1; print hash}' "$WORK/SHA256SUMS")" || { kali_die "The signed checksum list did not contain exactly one SHA-256 entry for $FILENAME."; exit 1; }

if [[ -e "$OUTPUT_ISO" || -L "$OUTPUT_ISO" ]]; then
  kali_validate_private_file "$OUTPUT_ISO"
  ACTUAL_SHA="$(sha256sum -- "$OUTPUT_ISO" | awk '{print tolower($1)}')"
  [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { kali_die "Existing ISO failed the signed SHA-256 check and was left untouched: $OUTPUT_ISO"; exit 1; }
  printf 'Existing ISO passed the official signature and SHA-256 checks; it was not overwritten: %s\n' "$OUTPUT_ISO"
  exit 0
fi

curl -fIL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 "$BASE_URL/$FILENAME" -o /dev/null -D "$WORK/headers"
ISO_BYTES="$(awk 'BEGIN{IGNORECASE=1} tolower($1)=="content-length:" {gsub("\\r", "", $2); size=$2} END{if (size ~ /^[0-9]+$/) print size; else exit 1}' "$WORK/headers")" || { kali_die 'Official server did not provide a final ISO Content-Length; refusing a download without a storage check.'; exit 1; }
FREE_BYTES="$(df -PB1 -- "$OUTPUT_DIR" | awk 'NR==2 {print $4}')"
REQUIRED_BYTES=$((ISO_BYTES + 1073741824))
(( FREE_BYTES >= REQUIRED_BYTES )) || { kali_die "Not enough free storage for the official ISO plus a 1 GiB safety margin."; exit 1; }

TEMP_ISO="$WORK/$FILENAME"
curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 0 \
  --retry 3 --retry-delay 2 --output "$TEMP_ISO" "$BASE_URL/$FILENAME"
ACTUAL_SHA="$(sha256sum -- "$TEMP_ISO" | awk '{print tolower($1)}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { kali_die 'Downloaded ISO SHA-256 did not match the signed Kali manifest; the partial file was discarded.'; exit 1; }
chmod 600 -- "$TEMP_ISO"
ln -- "$TEMP_ISO" "$OUTPUT_ISO" || { kali_die "Could not install the verified ISO without overwriting an existing file: $OUTPUT_ISO"; exit 1; }
printf 'Downloaded and verified official Kali %s installer ISO (signature and SHA-256): %s\n' "$RELEASE" "$OUTPUT_ISO"
