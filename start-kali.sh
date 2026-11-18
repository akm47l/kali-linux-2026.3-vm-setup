#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QMP="$ROOT/qmp.sock"
DISK="$ROOT/disk.qcow2"
PASSWORD_FILE="$ROOT/vnc-password.txt"

if [[ ! -r "$DISK" ]]; then
  echo "Missing local VM disk: $DISK" >&2
  exit 1
fi
if [[ ! -r "$PASSWORD_FILE" ]] || [[ ! -s "$PASSWORD_FILE" ]]; then
  echo "Missing VNC password file: $PASSWORD_FILE" >&2
  exit 1
fi

rm -f "$QMP" "$ROOT/qemu.pid"
qemu-system-x86_64 \
  -name kali-vm \
  -machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 6G \
  -drive file="$DISK",if=virtio,format=qcow2,cache=writeback \
  -boot order=c \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -vnc 127.0.0.1:1,password=on \
  -qmp "unix:$QMP,server=on,wait=off" \
  -display none -monitor none \
  -serial "file:$ROOT/runtime-serial.log" \
  -pidfile "$ROOT/qemu.pid" \
  >"$ROOT/qemu.log" 2>&1 &
qemu_pid=$!
cleanup() {
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
python3 - "$QMP" "$PASSWORD_FILE" <<'PY'
import json, pathlib, socket, sys, time
sock_path, password_path = sys.argv[1:]
password = pathlib.Path(password_path).read_text().strip()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(100):
    try:
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit('QMP socket did not become available')
f = s.makefile('rwb', buffering=0)
json.loads(f.readline())
f.write(b'{"execute":"qmp_capabilities"}\n')
if 'error' in json.loads(f.readline()):
    raise SystemExit('QMP capability negotiation failed')
command = {"execute":"set_password","arguments":{"protocol":"vnc","password":password}}
f.write(json.dumps(command).encode()+b'\n')
reply = json.loads(f.readline())
if 'error' in reply:
    raise SystemExit('Could not set the VNC password')
s.close()
PY
wait "$qemu_pid"
trap - EXIT INT TERM
