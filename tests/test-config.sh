#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ "$(kali_size_bytes 2G)" == 2147483648 ]] || fail '2G conversion'
[[ "$(kali_size_bytes 64M)" == 67108864 ]] || fail '64M conversion'
! kali_size_bytes 0G >/dev/null 2>&1 || fail 'zero-size rejected'

KALI_PROFILE=minimal kali_load_config
[[ "$PROFILE" == minimal && "$MEMORY" == 2G && "$CPU_CORES" == 1 ]] || fail 'minimal profile values'
KALI_PROFILE=standard kali_load_config
[[ "$PROFILE" == standard && "$MEMORY" == 4G && "$CPU_CORES" == auto ]] || fail 'standard profile values'
KALI_PROFILE=advanced kali_load_config
[[ "$PROFILE" == advanced && "$MEMORY" == 8G && "$CPU_CORES" == 4 ]] || fail 'advanced profile values'
kali_load_config
[[ "$NETWORK_MODE" == NAT && "$SSH_HOST_PORT" == auto && "$VNC_DISPLAY" == auto ]] || fail 'per-user safe defaults'

TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
# Intentional literal input: the parser must reject this instead of executing it.
# shellcheck disable=SC2016
printf 'NETWORK_MODE=$(touch /tmp/kali-config-injected)\n' > "$TEMP/bad.conf"
if kali_read_config_file "$TEMP/bad.conf" test >/dev/null 2>&1; then fail 'shell expressions rejected'; fi
[[ ! -e /tmp/kali-config-injected ]] || fail 'config parser executed shell input'
printf 'UNKNOWN=value\n' > "$TEMP/unknown.conf"
if kali_read_config_file "$TEMP/unknown.conf" test >/dev/null 2>&1; then fail 'unknown keys rejected'; fi
printf 'PROFILE=advanced\n' > "$TEMP/profile.conf"
if kali_read_config_file "$TEMP/profile.conf" user >/dev/null 2>&1; then fail 'profile must be selected through --profile'; fi

ARGS=()
NETWORK_MODE=OFFLINE
kali_build_network_args OFFLINE ARGS "$TEMP/net.sock"
[[ "${ARGS[*]}" == '-nic none' ]] || fail 'offline network has no NIC'
NETWORK_MODE=NAT
RESOLVED_SSH_HOST_PORT=2223 kali_build_network_args NAT ARGS "$TEMP/net.sock"
[[ "${ARGS[*]}" == *'hostfwd=tcp:127.0.0.1:2223-:22'* ]] || fail 'NAT forward is loopback-only'
[[ "${ARGS[*]}" != *'0.0.0.0'* && "${ARGS[*]}" != *'bridge'* ]] || fail 'NAT exposes neither public binds nor bridge'
kali_build_network_args ISOLATED ARGS "$TEMP/net.sock"
[[ "${ARGS[*]}" == *"listen=unix:$TEMP/net.sock"* ]] || fail 'isolated mode uses a local Unix socket'

printf 'PASS: config parsing, resource profiles, and network-mode checks\n'
