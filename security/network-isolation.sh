#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
(($# == 0)) || { kali_die 'network-isolation accepts no arguments.'; exit 2; }
kali_load_config
kali_resolve_ports
ARGS=()
kali_build_network_args "$NETWORK_MODE" ARGS "$KALI_RUNTIME_DIR/isolated-net.sock"
if [[ "${ARGS[*]}" == *'0.0.0.0'* || "${ARGS[*]}" == *bridge* ]]; then
  kali_die 'Refusing network arguments that bind publicly or request a bridge.'
  exit 1
fi
printf 'Network mode: %s\n' "$NETWORK_MODE"
case "$NETWORK_MODE" in
  OFFLINE) printf 'No virtual NIC will be attached.\n' ;;
  NAT) printf 'QEMU user-mode NAT; SSH forwarding listens only on 127.0.0.1:%s. No bridge is enabled.\n' "$RESOLVED_SSH_HOST_PORT" ;;
  ISOLATED) printf 'Peer-only QEMU socket network; listener uses a private per-user Unix socket. No host bridge or Internet NAT.\n' ;;
esac
printf 'Check result: this configuration does not request a public VNC/SSH bind or bridge.\n'
