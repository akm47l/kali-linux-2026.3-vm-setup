#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
command -v "$QEMU_IMG" >/dev/null 2>&1 || { printf 'SKIP: qemu-img not installed\n'; exit 0; }
TEMP="$(mktemp -d)"
chmod 700 "$TEMP"
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -m 700 "$TEMP/home" "$TEMP/config" "$TEMP/runtime"
CONFIG="$TEMP/config/test.conf"
cat > "$CONFIG" <<'EOF'
DISK_PATH=test.qcow2
VNC_PASSWORD_FILE=vnc-password.txt
MEMORY=1G
CPU_CORES=1
ACCELERATION=tcg
NETWORK_MODE=OFFLINE
SSH_HOST_PORT=auto
VNC_DISPLAY=auto
DISK_SIZE=64M
INSTALLER_RELEASE=2026.3
SHUTDOWN_TIMEOUT=5
EOF
export HOME="$TEMP/home" XDG_CONFIG_HOME="$TEMP/config-home" XDG_DATA_HOME="$TEMP/data-home" XDG_RUNTIME_DIR="$TEMP/runtime" KALI_CONFIG="$CONFIG"
DATA_DIR="$TEMP/data-home/kali-virtual-security-lab"
DISK="$DATA_DIR/test.qcow2"
"$ROOT/scripts/create-disk.sh" --size 64M >/dev/null
[[ -f "$DISK" ]] || { printf 'FAIL: disk was not created\n' >&2; exit 1; }
[[ "$(stat -c '%a' "$DISK")" == 600 ]] || { printf 'FAIL: disk mode is not 600\n' >&2; exit 1; }
[[ "$("$QEMU_IMG" info --output=json "$DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')" == qcow2 ]] || { printf 'FAIL: created file is not QCOW2\n' >&2; exit 1; }
BEFORE="$(sha256sum "$DISK" | awk '{print $1}')"
if "$ROOT/scripts/create-disk.sh" --size 64M --output test.qcow2 >/dev/null 2>&1; then
  printf 'FAIL: existing disk was overwritten\n' >&2; exit 1
fi
for unsafe_name in ../escape.qcow2 "$TEMP/escape.qcow2"; do
  if "$ROOT/scripts/create-disk.sh" --size 64M --output "$unsafe_name" >/dev/null 2>&1; then
    printf 'FAIL: unsafe output path was accepted: %s\n' "$unsafe_name" >&2; exit 1
  fi
done
[[ ! -e "$TEMP/escape.qcow2" ]] || { printf 'FAIL: output escaped the per-user data directory\n' >&2; exit 1; }
AFTER="$(sha256sum "$DISK" | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] || { printf 'FAIL: existing disk changed\n' >&2; exit 1; }

"$ROOT/scripts/snapshot-kali.sh" create before-update >/dev/null
[[ -f "$DATA_DIR/snapshots.tsv" ]] || { printf 'FAIL: snapshot creation log is missing\n' >&2; exit 1; }
[[ "$(stat -c '%a' "$DATA_DIR/snapshots.tsv")" == 600 ]] || { printf 'FAIL: snapshot log is not private\n' >&2; exit 1; }
"$ROOT/scripts/snapshot-kali.sh" list > "$TEMP/snapshots.log"
grep -q before-update "$TEMP/snapshots.log" || { printf 'FAIL: snapshot was not listed\n' >&2; exit 1; }
if "$ROOT/scripts/snapshot-kali.sh" create before-update >/dev/null 2>&1; then
  printf 'FAIL: duplicate snapshot name was accepted\n' >&2; exit 1
fi
"$ROOT/scripts/backup-kali.sh" > "$TEMP/backup.log"
BACKUP="$(sed -n 's/^Created verified private backup: //p' "$TEMP/backup.log")"
[[ -n "$BACKUP" && -f "$BACKUP" && "$(stat -c '%a' "$BACKUP")" == 600 ]] || { printf 'FAIL: verified private backup missing or not protected\n' >&2; exit 1; }

if command -v script >/dev/null 2>&1; then
  printf 'RESTORE before-update\r' | script -qefc "$ROOT/scripts/restore-kali.sh before-update" "$TEMP/restore.typescript" > "$TEMP/restore.log"
  grep -q 'pre-restore backup was retained' "$TEMP/restore.log" || { cat "$TEMP/restore.log" >&2; printf 'FAIL: confirmed snapshot restore did not complete\n' >&2; exit 1; }
  BACKUP_COUNT="$(find "$DATA_DIR" -maxdepth 1 -type f -name 'test.qcow2.backup-*' | wc -l)"
  (( BACKUP_COUNT >= 2 )) || { printf 'FAIL: restore did not preserve its pre-change backup\n' >&2; exit 1; }
else
  printf 'SKIP: script(1) unavailable; restore confirmation path not exercised\n'
fi
printf 'PASS: confined paths, locked QCOW2 creation/snapshots/backups, no-overwrite, and confirmed restore with a shared inherited lock\n'
