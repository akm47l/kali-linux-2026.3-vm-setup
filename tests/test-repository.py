#!/usr/bin/env python3
"""Repository hygiene and local documentation-link checks; no network access."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_SUFFIXES = {'.iso', '.qcow', '.qcow2', '.img', '.raw', '.vmdk', '.vdi', '.vhd', '.vhdx', '.ova'}
MAX_TRACKED_BYTES = 25 * 1024 * 1024

def fail(message: str) -> None:
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)

try:
    raw_files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    file_names = raw_files.decode().split('\0')
except (subprocess.CalledProcessError, FileNotFoundError):
    fail('git ls-files could not inspect repository contents')
file_names = [item for item in file_names if item]
for name in file_names:
    path = ROOT / name
    if path.suffix.lower() in FORBIDDEN_SUFFIXES:
        fail(f'VM image/ISO must never be part of the repository: {name}')
    if path.is_file() and path.stat().st_size > MAX_TRACKED_BYTES:
        fail(f'unexpected repository file larger than 25 MiB: {name}')

for name in ('disk.qcow2', 'installer.iso', 'runtime/qmp.sock', 'runtime/qemu.log', 'vnc-password.txt', 'disk.qcow2.backup-20261119'):
    result = subprocess.run(['git', 'check-ignore', '-q', name], cwd=ROOT)
    if result.returncode != 0:
        fail(f'.gitignore does not protect {name}')

preseed = (ROOT / 'preseed.cfg').read_text(encoding='utf-8')
if re.search(r'(?im)^\s*d-i\s+passwd/[^\n]*(?:password|crypted)', preseed):
    fail('preseed.cfg must not set or hash a password')
for unsafe in ('partman/confirm boolean true', 'partman/confirm_nooverwrite boolean true', 'partman-auto/disk string'):
    if unsafe in preseed:
        fail(f'preseed.cfg must not auto-select or confirm a target disk: {unsafe}')

markdown_files = [ROOT / name for name in file_names if name.lower().endswith('.md')]
link_re = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
for md in markdown_files:
    text = md.read_text(encoding='utf-8')
    for raw in link_re.findall(text):
        target = raw.strip().split()[0].strip('<>')
        parsed = urlsplit(target)
        if parsed.scheme or target.startswith('#') or target.startswith('mailto:'):
            continue
        local = target.split('#', 1)[0]
        if not local:
            continue
        resolved = (md.parent / local).resolve()
        try:
            resolved.relative_to(ROOT.resolve())
        except ValueError:
            fail(f'local link escapes repository in {md.relative_to(ROOT)}: {target}')
        if not resolved.exists():
            fail(f'broken local Markdown link in {md.relative_to(ROOT)}: {target}')

for required in ('LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md', '.github/workflows/validate.yml'):
    if not (ROOT / required).is_file():
        fail(f'required project file is missing: {required}')
print('PASS: no repository VM images or large files, protected runtime artifacts, safe preseed defaults, local links valid')
