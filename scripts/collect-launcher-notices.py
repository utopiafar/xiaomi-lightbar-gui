"""Collect licenses for the dependencies embedded in the Windows launcher."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--format-version', '1',
    '--manifest-path', str(root / 'windows-launcher' / 'Cargo.toml'),
], text=True))
sections = ['Third-party notices for the single-file Windows launcher.\n']
for package in sorted(metadata['packages'], key=lambda item: (item['name'], item['version'])):
    if not package.get('source'):
        continue
    package_dir = Path(package['manifest_path']).parent
    files = sorted({*package_dir.glob('LICENSE*'), *package_dir.glob('COPYING*')})
    sections.append('\n' + '=' * 72 + '\n')
    sections.append(f"{package['name']} {package['version']} ({package.get('license')})\n")
    for file in files:
        if file.is_file():
            sections.append(f'\n--- {file.name} ---\n')
            sections.append(file.read_text(encoding='utf-8', errors='replace'))
            sections.append('\n')
sections.append('\n' + '=' * 72 + '\nMicrosoft Visual C++ runtime files\n')
sections.append('Unmodified Microsoft Visual C++ redistributable files are included from the Visual Studio installation.\n')
sections.append('Microsoft license and redistribution information: https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files\n')
Path(sys.argv[1]).write_text(''.join(sections), encoding='utf-8')
