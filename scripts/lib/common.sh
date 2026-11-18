#!/usr/bin/env bash
# Shared, non-executable configuration and safety helpers for Kali Virtual Security Lab.

KALI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
KALI_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME:?HOME must be set}/.config}/kali-virtual-security-lab"
KALI_DATA_HOME="${XDG_DATA_HOME:-${HOME:?HOME must be set}/.local/share}/kali-virtual-security-lab"
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  KALI_RUNTIME_DIR="${XDG_RUNTIME_DIR}/kali-virtual-security-lab"
else
  KALI_RUNTIME_DIR="${TMPDIR:-/tmp}/kali-virtual-security-lab-$(id -u)"
fi
KALI_CONFIG_FILE="${KALI_CONFIG:-$KALI_ROOT/config/defaults.conf}"
KALI_USER_CONFIG_FILE="$KALI_CONFIG_HOME/config.conf"

kali_die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
kali_note() { printf '%s\n' "$*" >&2; }

kali_set_defaults() {
  PROFILE=standard
  VM_NAME=kali-vm
  DISK_PATH=disk.qcow2
  VNC_PASSWORD_FILE=vnc-password.txt
  MEMORY=4G
  CPU_CORES=auto
  ACCELERATION=auto
  NETWORK_MODE=NAT
  SSH_HOST_PORT=auto
  VNC_DISPLAY=auto
  DISK_SIZE=80G
  INSTALLER_RELEASE=2026.3
  SHUTDOWN_TIMEOUT=60
}

kali_read_config_file() {
  local file="$1" origin="${2:-custom}" line key value
  [[ -f "$file" && -r "$file" ]] || { kali_die "Configuration file is not readable: $file"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9_./:+-]+)$ ]]; then
      kali_die "Invalid configuration syntax in $file. Use KEY=value with no quotes or shell expressions."
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      PROFILE)
        [[ "$origin" == defaults ]] || { kali_die "PROFILE is selected with --profile, not in $file"; return 1; }
        ;;
      VM_NAME|DISK_PATH|VNC_PASSWORD_FILE|MEMORY|CPU_CORES|ACCELERATION|NETWORK_MODE|SSH_HOST_PORT|VNC_DISPLAY|DISK_SIZE|INSTALLER_RELEASE|SHUTDOWN_TIMEOUT) ;;
      *) kali_die "Unsupported configuration key '$key' in $file"; return 1 ;;
    esac
    printf -v "$key" '%s' "$value"
  done < "$file"
}

kali_load_config() {
  kali_set_defaults
  kali_read_config_file "$KALI_ROOT/config/defaults.conf" defaults || return 1
  if [[ -n "${KALI_PROFILE:-}" ]]; then PROFILE="$KALI_PROFILE"; fi
  [[ "$PROFILE" =~ ^(minimal|standard|advanced)$ ]] || { kali_die "Unknown profile '$PROFILE' (choose minimal, standard, or advanced)."; return 1; }
  kali_read_config_file "$KALI_ROOT/config/profiles/$PROFILE.conf" profile || return 1
  if [[ -f "$KALI_USER_CONFIG_FILE" ]]; then
    kali_read_config_file "$KALI_USER_CONFIG_FILE" user || return 1
  fi
  if [[ "$KALI_CONFIG_FILE" != "$KALI_ROOT/config/defaults.conf" ]]; then
    kali_read_config_file "$KALI_CONFIG_FILE" custom || return 1
  fi
  kali_validate_config
}

kali_validate_config() {
  [[ "$VM_NAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { kali_die 'VM_NAME must use 1-64 letters, digits, dots, underscores, or hyphens.'; return 1; }
  [[ -n "$DISK_PATH" && -n "$VNC_PASSWORD_FILE" ]] || { kali_die 'DISK_PATH and VNC_PASSWORD_FILE must not be empty.'; return 1; }
  [[ "$MEMORY" == auto || "$MEMORY" =~ ^[1-9][0-9]*[KMG]$ ]] || { kali_die 'MEMORY must be auto or a positive integer followed by K, M, or G.'; return 1; }
  [[ "$CPU_CORES" == auto || "$CPU_CORES" =~ ^[1-9][0-9]*$ ]] || { kali_die 'CPU_CORES must be auto or a positive integer.'; return 1; }
  [[ "$ACCELERATION" =~ ^(auto|kvm|tcg)$ ]] || { kali_die 'ACCELERATION must be auto, kvm, or tcg.'; return 1; }
  [[ "$NETWORK_MODE" =~ ^(OFFLINE|NAT|ISOLATED)$ ]] || { kali_die 'NETWORK_MODE must be OFFLINE, NAT, or ISOLATED.'; return 1; }
  [[ "$SSH_HOST_PORT" == auto || ( "$SSH_HOST_PORT" =~ ^[0-9]{1,5}$ && SSH_HOST_PORT -ge 1 && SSH_HOST_PORT -le 65535 ) ]] || { kali_die 'SSH_HOST_PORT must be auto or between 1 and 65535.'; return 1; }
  [[ "$VNC_DISPLAY" == auto || ( "$VNC_DISPLAY" =~ ^[0-9]{1,3}$ && VNC_DISPLAY -ge 0 && VNC_DISPLAY -le 59635 ) ]] || { kali_die 'VNC_DISPLAY must be auto or a value producing TCP port 5900-65535.'; return 1; }
  [[ "$DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || { kali_die 'DISK_SIZE must be a positive integer followed by K, M, or G.'; return 1; }
  [[ "$INSTALLER_RELEASE" =~ ^[0-9]{4}\.[0-9]+$ ]] || { kali_die 'INSTALLER_RELEASE must look like 2026.3.'; return 1; }
  if [[ ! "$SHUTDOWN_TIMEOUT" =~ ^[0-9]{1,3}$ ]] || (( SHUTDOWN_TIMEOUT < 1 || SHUTDOWN_TIMEOUT > 600 )); then
    kali_die 'SHUTDOWN_TIMEOUT must be between 1 and 600 seconds.'
    return 1
  fi
}

kali_size_bytes() {
  local input="$1" number unit multiplier
  [[ "$input" =~ ^([1-9][0-9]*)([KMG])$ ]] || return 1
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in K) multiplier=1024 ;; M) multiplier=1048576 ;; G) multiplier=1073741824 ;; esac
  (( number <= 8796093022207 / multiplier )) || return 1
  printf '%s\n' "$((number * multiplier))"
}

kali_resolve_resources() {
  local cpus mem_kib mem_bytes cgroup_max cgroup_current reserve=536870912
  cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
  if [[ "$CPU_CORES" == auto ]]; then
    RESOLVED_CPUS=$((cpus / 2))
    (( RESOLVED_CPUS >= 1 )) || RESOLVED_CPUS=1
    (( RESOLVED_CPUS <= 4 )) || RESOLVED_CPUS=4
  else
    RESOLVED_CPUS="$CPU_CORES"
  fi
  (( RESOLVED_CPUS <= cpus )) || { kali_die "Requested $RESOLVED_CPUS CPU cores, but only $cpus are available to this process."; return 1; }

  mem_kib="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || mem_kib=0
  mem_bytes=$((mem_kib * 1024))
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    read -r cgroup_max < /sys/fs/cgroup/memory.max || true
    if [[ "$cgroup_max" =~ ^[0-9]+$ ]] && (( cgroup_max > 0 )); then
      read -r cgroup_current < /sys/fs/cgroup/memory.current || cgroup_current=0
      [[ "$cgroup_current" =~ ^[0-9]+$ ]] || cgroup_current=0
      (( cgroup_max > cgroup_current )) && (( cgroup_max - cgroup_current < mem_bytes )) && mem_bytes=$((cgroup_max - cgroup_current))
    fi
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    read -r cgroup_max < /sys/fs/cgroup/memory/memory.limit_in_bytes || true
    read -r cgroup_current < /sys/fs/cgroup/memory/memory.usage_in_bytes || cgroup_current=0
    if [[ "$cgroup_max" =~ ^[0-9]+$ && "$cgroup_current" =~ ^[0-9]+$ ]] && (( cgroup_max < 9223372036854771712 && cgroup_max > cgroup_current )); then
      (( cgroup_max - cgroup_current < mem_bytes )) && mem_bytes=$((cgroup_max - cgroup_current))
    fi
  fi
  if [[ "$MEMORY" == auto ]]; then
    RESOLVED_MEMORY_BYTES=$((mem_bytes / 4))
    (( RESOLVED_MEMORY_BYTES > 8589934592 )) && RESOLVED_MEMORY_BYTES=8589934592
    RESOLVED_MEMORY_BYTES=$((RESOLVED_MEMORY_BYTES / 268435456 * 268435456))
    (( RESOLVED_MEMORY_BYTES >= 1073741824 )) || { kali_die 'Less than 1 GiB of memory is available; cannot choose a safe automatic VM allocation.'; return 1; }
  else
    RESOLVED_MEMORY_BYTES="$(kali_size_bytes "$MEMORY")" || { kali_die "Invalid memory size '$MEMORY'."; return 1; }
  fi
  (( mem_bytes > reserve && RESOLVED_MEMORY_BYTES <= mem_bytes - reserve )) || { kali_die "Requested VM memory (${MEMORY}) exceeds available memory after reserving 512 MiB for the host."; return 1; }
  # shellcheck disable=SC2034 # consumed by scripts sourcing this library
  RESOLVED_MEMORY_MIB=$(( (RESOLVED_MEMORY_BYTES + 1048575) / 1048576 ))
}

kali_resolve_ports() {
  local uid offset index candidate found
  uid="$(id -u)"
  if [[ "$SSH_HOST_PORT" == auto ]]; then
    offset=$((uid % 100))
    found=0
    for ((index = 0; index < 100; index++)); do
      candidate=$((2200 + (offset + index) % 100))
      if kali_port_available "$candidate"; then RESOLVED_SSH_HOST_PORT="$candidate"; found=1; break; fi
    done
    (( found == 1 )) || { kali_die 'No free loopback SSH forwarding port is available in 2200-2299.'; return 1; }
  else
    RESOLVED_SSH_HOST_PORT="$SSH_HOST_PORT"
    if [[ "$NETWORK_MODE" == NAT ]]; then
      kali_port_available "$RESOLVED_SSH_HOST_PORT" || { kali_die "127.0.0.1:$RESOLVED_SSH_HOST_PORT is already in use."; return 1; }
    fi
  fi
  if [[ "$VNC_DISPLAY" == auto ]]; then
    offset=$((uid % 100))
    found=0
    for ((index = 0; index < 100; index++)); do
      candidate=$((offset + index))
      if (( candidate + 5900 <= 65535 )) && kali_port_available "$((5900 + candidate))"; then RESOLVED_VNC_DISPLAY="$candidate"; found=1; break; fi
    done
    (( found == 1 )) || { kali_die 'No free loopback VNC port is available.'; return 1; }
  else
    RESOLVED_VNC_DISPLAY="$VNC_DISPLAY"
  fi
  kali_port_available "$((5900 + RESOLVED_VNC_DISPLAY))" || { kali_die "127.0.0.1:$((5900 + RESOLVED_VNC_DISPLAY)) is already in use."; return 1; }
}

kali_qemu_binary() { printf '%s\n' "${QEMU_SYSTEM:-qemu-system-x86_64}"; }
kali_qemu_img_binary() { printf '%s\n' "${QEMU_IMG:-qemu-img}"; }
kali_disk_path() { if [[ "$DISK_PATH" = /* ]]; then printf '%s\n' "$DISK_PATH"; else printf '%s/%s\n' "$KALI_DATA_HOME" "$DISK_PATH"; fi; }
kali_password_path() { if [[ "$VNC_PASSWORD_FILE" = /* ]]; then printf '%s\n' "$VNC_PASSWORD_FILE"; else printf '%s/%s\n' "$KALI_CONFIG_HOME" "$VNC_PASSWORD_FILE"; fi; }
kali_path_owner_is_current() { [[ "$(stat -c '%u' -- "$1" 2>/dev/null || true)" == "$(id -u)" ]]; }

kali_ensure_private_dir() {
  local dir="$1" mode
  if [[ ! -e "$dir" ]]; then
    mkdir -p -- "$dir" || { kali_die "Could not create directory: $dir"; return 1; }
    chmod 700 -- "$dir"
  fi
  [[ -d "$dir" && ! -L "$dir" ]] || { kali_die "Expected a real directory: $dir"; return 1; }
  kali_path_owner_is_current "$dir" || { kali_die "Directory must be owned by the current user: $dir"; return 1; }
  mode="$(stat -c '%a' -- "$dir" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 077) != 0 )); then
    kali_die "Directory is not private to this user: $dir (mode ${mode:-unknown}); run chmod 700 '$dir'."
    return 1
  fi
}

kali_prepare_user_dirs() {
  kali_ensure_private_dir "$KALI_CONFIG_HOME" || return 1
  kali_ensure_private_dir "$KALI_DATA_HOME" || return 1
  kali_ensure_private_dir "$KALI_RUNTIME_DIR" || return 1
  if [[ ! -e "$KALI_RUNTIME_DIR/sessions" ]]; then
    mkdir -- "$KALI_RUNTIME_DIR/sessions" || return 1
    chmod 700 -- "$KALI_RUNTIME_DIR/sessions"
  fi
  kali_ensure_private_dir "$KALI_RUNTIME_DIR/sessions"
}

kali_validate_private_file() {
  local file="$1" mode
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || { kali_die "Expected a readable regular file, not a symlink: $file"; return 1; }
  kali_path_owner_is_current "$file" || { kali_die "File must be owned by the current user: $file"; return 1; }
  mode="$(stat -c '%a' -- "$file" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 077) != 0 )); then
    kali_die "File is not private to this user: $file (mode ${mode:-unknown}); run chmod 600 '$file'."
    return 1
  fi
}

kali_validate_vnc_password_file() {
  local file="$1"
  kali_validate_private_file "$file" || return 1
  python3 - "$file" <<'PY'
import pathlib, sys
try:
    raw = pathlib.Path(sys.argv[1]).read_bytes()
except OSError:
    print('ERROR: Could not read the VNC password file.', file=sys.stderr)
    raise SystemExit(1)
if raw.endswith(b'\n'):
    raw = raw[:-1]
    if raw.endswith(b'\r'):
        raw = raw[:-1]
if not raw or len(raw) > 8 or any(byte < 0x20 or byte > 0x7e for byte in raw):
    print('ERROR: Classic VNC authentication accepts only 1-8 printable ASCII bytes; longer passwords would be truncated.', file=sys.stderr)
    raise SystemExit(1)
PY
}

kali_validate_socket() {
  local socket_path="$1" mode
  [[ -S "$socket_path" && ! -L "$socket_path" ]] || { kali_die "Expected a Unix socket at $socket_path"; return 1; }
  kali_path_owner_is_current "$socket_path" || { kali_die 'QMP socket is not owned by the current user.'; return 1; }
  mode="$(stat -c '%a' -- "$socket_path" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 077) != 0 )); then
    kali_die 'QMP socket permissions are not private to the current user.'
    return 1
  fi
}

kali_session_pid() {
  local dir="$1" pidfile="$1/qemu.pid" mode
  [[ -d "$dir" && ! -L "$dir" && -f "$pidfile" && ! -L "$pidfile" ]] || return 1
  kali_path_owner_is_current "$dir" && kali_path_owner_is_current "$pidfile" || return 1
  mode="$(stat -c '%a' -- "$pidfile" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || return 1
  IFS= read -r pid < "$pidfile" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$pid"
}

kali_pid_is_our_qemu() {
  local pid="$1" socket_path="$2" uid exe arg found=0
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" && -r "/proc/$pid/status" ]] || return 1
  uid="$(awk '/^Uid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  [[ "$uid" == "$(id -u)" ]] || return 1
  local -a argv=()
  mapfile -d '' -t argv < "/proc/$pid/cmdline" || true
  ((${#argv[@]} > 0)) || return 1
  exe="${argv[0]##*/}"
  [[ "$exe" == qemu-system-x86_64 || "$exe" == qemu-kvm || "$exe" == kvm ]] || return 1
  for arg in "${argv[@]}"; do
    [[ "$arg" == "unix:$socket_path"* ]] && found=1
  done
  (( found == 1 ))
}

kali_active_sessions() {
  local sessions_dir="$KALI_RUNTIME_DIR/sessions" dir pid sock
  [[ -d "$sessions_dir" && ! -L "$sessions_dir" ]] || return 0
  while IFS= read -r -d '' dir; do
    pid="$(kali_session_pid "$dir" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      sock="$dir/qmp.sock"
      if kali_pid_is_our_qemu "$pid" "$sock"; then printf '%s\t%s\n' "$dir" "$pid"; fi
    fi
  done < <(find "$sessions_dir" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print0 2>/dev/null)
}

kali_choose_accelerator() {
  local qemu
  qemu="$(kali_qemu_binary)"
  if [[ "$ACCELERATION" == tcg ]]; then RESOLVED_ACCEL=tcg; return 0; fi
  if [[ -r /dev/kvm && -w /dev/kvm ]] && "$qemu" -accel help 2>&1 | grep -qE '(^|[[:space:]])kvm([[:space:]]|$)'; then
    RESOLVED_ACCEL=kvm
    return 0
  fi
  if [[ "$ACCELERATION" == kvm ]]; then
    kali_die 'KVM was requested but /dev/kvm is unavailable or not accessible; select ACCELERATION=auto or tcg.'
    return 1
  fi
  # shellcheck disable=SC2034 # consumed by scripts sourcing this library
  RESOLVED_ACCEL=tcg
  kali_note 'KVM is unavailable to this user; falling back to QEMU TCG (software emulation).'
}

kali_port_available() {
  local port="$1" address="${2:-127.0.0.1}"
  python3 - "$address" "$port" <<'PY'
import socket, sys
sock = socket.socket()
try:
    sock.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

kali_build_network_args() {
  local mode="${1:-$NETWORK_MODE}" qemu_args_name="${2:-KALI_NETWORK_ARGS}"
  # shellcheck disable=SC2034 # the nameref writes into the caller's named array
  local -n out="$qemu_args_name"
  out=()
  case "$mode" in
    OFFLINE) out=(-nic none) ;;
    NAT)
      local ssh_port="${RESOLVED_SSH_HOST_PORT:-$SSH_HOST_PORT}"
      kali_port_available "$ssh_port" || { kali_die "127.0.0.1:$ssh_port is already in use; change SSH_HOST_PORT or stop the service."; return 1; }
      out=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" -device "virtio-net-pci,netdev=net0")
      ;;
    ISOLATED)
      local socket_path="${3:-$KALI_RUNTIME_DIR/isolated-net.sock}"
      # shellcheck disable=SC2034 # the nameref writes into the caller's named array
      out=(-netdev "socket,id=net0,listen=unix:${socket_path}" -device "virtio-net-pci,netdev=net0")
      ;;
    *) kali_die "Unknown network mode '$mode'."; return 1 ;;
  esac
}

kali_qemu_img_format() {
  local imgbin
  imgbin="$(kali_qemu_img_binary)"
  "$imgbin" info --output=json -- "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format", ""))' 2>/dev/null
}

kali_validate_qcow2() {
  local path="$1" format
  kali_validate_private_file "$path" || return 1
  [[ -w "$path" ]] || { kali_die "QCOW2 disk must be writable by its owner: $path"; return 1; }
  format="$(kali_qemu_img_format "$path" 2>/dev/null || true)"
  [[ "$format" == qcow2 ]] || { kali_die "Expected a QCOW2 disk at $path (detected: ${format:-unknown})."; return 1; }
}

kali_require_vm_stopped() {
  local active
  active="$(kali_active_sessions)"
  [[ -z "$active" ]] || { kali_die "This operation requires the current user's Kali VM to be fully stopped."; return 1; }
}

kali_ensure_private_runtime() { kali_prepare_user_dirs; }

kali_check_disk_free() {
  local path="$1" virtual_bytes="$2" free_bytes required_bytes margin_bytes parent
  parent="$(dirname -- "$path")"
  [[ -d "$parent" ]] || mkdir -p -- "$parent" || { kali_die "Could not create disk directory: $parent"; return 1; }
  kali_path_owner_is_current "$parent" || { kali_die "Disk directory must be owned by the current user: $parent"; return 1; }
  local mode
  mode="$(stat -c '%a' -- "$parent" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 077) != 0 )); then
    kali_die "Disk directory is not private to this user: $parent"
    return 1
  fi
  free_bytes="$(df -PB1 -- "$parent" | awk 'NR==2 {print $4}')"
  [[ "$free_bytes" =~ ^[0-9]+$ ]] || { kali_die "Could not determine free space for $parent"; return 1; }
  margin_bytes=$((virtual_bytes / 10))
  (( margin_bytes >= 2147483648 )) || margin_bytes=2147483648
  required_bytes="$margin_bytes"
  (( free_bytes >= required_bytes )) || { kali_die "Insufficient free space in $parent: the QCOW2 image is sparse, but at least $((required_bytes / 1073741824)) GiB free is required to reduce the risk of filling the host filesystem."; return 1; }
}

kali_record_session_metadata() {
  local dir="$1" accel="$2" mode="$3" memory_mib="$4" cpus="$5" ssh_port="$6" vnc_display="$7"
  printf 'uid=%s\nvm_name=%s\nacceleration=%s\nnetwork_mode=%s\nmemory_mib=%s\ncpu_cores=%s\nssh_host_port=%s\nvnc_display=%s\nstarted_utc=%s\n' \
    "$(id -u)" "$VM_NAME" "$accel" "$mode" "$memory_mib" "$cpus" "$ssh_port" "$vnc_display" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/metadata"
  chmod 600 -- "$dir/metadata"
}
