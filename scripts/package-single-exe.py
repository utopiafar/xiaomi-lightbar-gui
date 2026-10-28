"""Append a validated ZIP and an integrity footer to a Windows launcher PE."""
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import zipfile

MAGIC = b'LIGHTBAR_SFX_V1!'
stub, archive, output = map(Path, sys.argv[1:4])
if stub.read_bytes()[:2] != b'MZ':
    raise SystemExit('Launcher is not a Windows executable')
with zipfile.ZipFile(archive) as bundle:
    required = {'xiaomi_lightbar_desktop.exe', 'lightbar_core.dll', 'flutter_windows.dll',
                'cnativeapi.dll', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin'}
    missing = required.difference(bundle.namelist())
    if missing:
        raise SystemExit('Missing bundle files: ' + ', '.join(sorted(missing)))
    corrupt = bundle.testzip()
    if corrupt:
        raise SystemExit('Corrupt bundle entry: ' + corrupt)

digest = hashlib.sha256()
with archive.open('rb') as source:
    while chunk := source.read(1024 * 1024):
        digest.update(chunk)

output.parent.mkdir(parents=True, exist_ok=True)
temporary = output.with_suffix('.tmp')
try:
    with temporary.open('wb') as target:
        with stub.open('rb') as source:
            shutil.copyfileobj(source, target)
        with archive.open('rb') as source:
            shutil.copyfileobj(source, target)
        target.write(struct.pack('<Q', archive.stat().st_size))
        target.write(digest.digest())
        target.write(MAGIC)
    os.replace(temporary, output)
finally:
    if temporary.exists():
        temporary.unlink()
print(f'Built single-file executable: {output}')
