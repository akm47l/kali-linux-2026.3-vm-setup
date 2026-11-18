#!/usr/bin/env python3
"""Small private QMP client; secrets are read from a protected file, never argv."""
import json
import os
import pathlib
import socket
import stat
import sys
import time


def fail(message: str, code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_password(path: str) -> str:
    try:
        p = pathlib.Path(path)
        info = p.lstat()
        if not stat.S_ISREG(info.st_mode) or p.is_symlink():
            fail("VNC password must be a regular file, not a symlink.")
        if info.st_uid != os.geteuid() or info.st_mode & 0o077:
            fail("VNC password file must be owned by the current user and private (mode 600 or stricter).")
        raw = p.read_bytes()
    except OSError:
        fail("Could not read the VNC password file.")
    if raw.endswith(b"\n"):
        raw = raw[:-1]
        if raw.endswith(b"\r"):
            raw = raw[:-1]
    if not raw or len(raw) > 8 or any(b < 0x20 or b > 0x7E for b in raw):
        fail("Classic VNC authentication accepts only 1-8 printable ASCII bytes; longer passwords would be truncated.")
    return raw.decode("ascii")


def read_json_line(stream) -> dict:
    line = stream.readline()
    if not line:
        fail("QMP closed the connection before replying.")
    try:
        return json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("QMP returned an invalid JSON response.")


def response(stream, request_id: str) -> dict:
    while True:
        item = read_json_line(stream)
        if "event" in item:
            continue
        if item.get("id") == request_id:
            if "error" in item:
                fail("QMP command failed; the secret value is not included in this error.")
            return item.get("return", {})


def main() -> None:
    if len(sys.argv) not in (3, 4):
        fail("Usage: qmp.py {set-password|status|powerdown|quit} SOCKET [PASSWORD_FILE]", 2)
    operation, socket_path = sys.argv[1:3]
    if operation not in {"set-password", "status", "powerdown", "quit"}:
        fail("Unsupported QMP operation.", 2)
    if operation == "set-password" and len(sys.argv) != 4:
        fail("set-password requires a password-file path.", 2)
    try:
        info = os.lstat(socket_path)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            fail("QMP socket must be a private Unix socket owned by the current user.")
    except OSError:
        fail("QMP socket is not available.")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    for _ in range(40):
        try:
            sock.connect(socket_path)
            break
        except OSError:
            time.sleep(0.1)
    else:
        fail("Could not connect to the current QEMU QMP socket.")
    try:
        with sock, sock.makefile("rwb", buffering=0) as stream:
            greeting = read_json_line(stream)
            if "QMP" not in greeting:
                fail("QMP greeting was missing.")
            stream.write(b'{"execute":"qmp_capabilities","id":"caps"}\r\n')
            response(stream, "caps")
            if operation == "set-password":
                password = read_password(sys.argv[3])
                command = {"execute": "set_password", "arguments": {"protocol": "vnc", "password": password}, "id": "set-password"}
                stream.write((json.dumps(command, separators=(",", ":")) + "\r\n").encode("ascii"))
                response(stream, "set-password")
                print("VNC authentication configured.")
            elif operation == "status":
                stream.write(b'{"execute":"query-status","id":"status"}\r\n')
                result = response(stream, "status")
                print(json.dumps(result, sort_keys=True))
            elif operation == "powerdown":
                stream.write(b'{"execute":"system_powerdown","id":"powerdown"}\r\n')
                response(stream, "powerdown")
                print("ACPI power-down request sent.")
            else:
                stream.write(b'{"execute":"quit","id":"quit"}\r\n')
                try:
                    response(stream, "quit")
                except SystemExit:
                    # QEMU may close QMP immediately after accepting quit.
                    pass
                print("QEMU quit request sent.")
    except (OSError, TimeoutError) as exc:
        fail("QMP connection failed or timed out.")


if __name__ == "__main__":
    main()
