#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<'EOF'
Kali Virtual Security Lab

Usage: ./kali.sh [--profile minimal|standard|advanced] COMMAND [arguments]

Commands:
  install       Download and verify an official Kali installer, create a new disk, and start its installer
  start         Start this user's VM
  stop          Request graceful guest shutdown; use --force only if you accept an abrupt QEMU quit
  restart       Stop gracefully and start again
  status        Show only this Linux user's VM sessions
  snapshot      List snapshots, or create one with: snapshot create NAME
  restore       Restore a snapshot after explicit confirmation and a backup
  backup        Create a private, verified backup of the stopped QCOW2 disk
  check         Check dependencies, private-file permissions, resources, and disk integrity
  create-disk   Create a new sparse QCOW2 disk without replacing existing data
  help          Show this help

Each Linux user has private config, VM data, runtime state, QMP sockets, and auto-selected loopback ports.
EOF
}
PROFILE_ARG=""
if [[ "${1:-}" == --profile ]]; then
  (($# >= 2)) || { printf 'ERROR: --profile requires minimal, standard, or advanced.\n' >&2; exit 2; }
  PROFILE_ARG="$2"
  shift 2
fi
COMMAND="${1:-help}"
[[ "$COMMAND" != help ]] || { usage; exit 0; }
shift || true
case "$COMMAND" in
  install) SCRIPT="$ROOT/installer/install.sh" ;;
  start) SCRIPT="$ROOT/scripts/start-kali.sh" ;;
  stop) SCRIPT="$ROOT/scripts/stop-kali.sh" ;;
  restart) SCRIPT="$ROOT/scripts/restart-kali.sh" ;;
  status) SCRIPT="$ROOT/scripts/status-kali.sh" ;;
  snapshot) SCRIPT="$ROOT/scripts/snapshot-kali.sh" ;;
  restore) SCRIPT="$ROOT/scripts/restore-kali.sh" ;;
  backup) SCRIPT="$ROOT/scripts/backup-kali.sh" ;;
  check) SCRIPT="$ROOT/scripts/check-requirements.sh" ;;
  create-disk) SCRIPT="$ROOT/scripts/create-disk.sh" ;;
  *) printf 'ERROR: Unknown command: %s\n\n' "$COMMAND" >&2; usage >&2; exit 2 ;;
esac
if [[ -n "$PROFILE_ARG" ]]; then export KALI_PROFILE="$PROFILE_ARG"; fi
exec "$SCRIPT" "$@"
