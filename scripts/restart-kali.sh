#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FORCE_ARGS=()
if [[ "${1:-}" == --force ]]; then FORCE_ARGS=(--force); shift; fi
(($# == 0)) || { printf 'Usage: %s [--force]\n' "$0" >&2; exit 2; }
"$SCRIPT_DIR/stop-kali.sh" "${FORCE_ARGS[@]}"
"$SCRIPT_DIR/start-kali.sh"
