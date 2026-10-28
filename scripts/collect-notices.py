"""Collect license texts for the native core and bundled Flutter packages."""
import json
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1])
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--format-version', '1',
    '--manifest-path', str(root / 'core' / 'Cargo.toml'),
], text=True))

entries = []
for package in metadata['packages']:
    if package.get('source'):
        entries.append((f"Rust: {package['name']} {package['version']} ({package.get('license')})",
                        pathlib.Path(package['manifest_path']).parent))

config_path = root / 'desktop' / '.dart_tool' / 'package_config.json'
config = json.loads(config_path.read_text(encoding='utf-8'))
base_uri = config_path.parent.as_uri() + '/'
for package in config['packages']:
    uri = urllib.parse.urljoin(base_uri, package['rootUri'])
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme == 'file':
        package_dir = pathlib.Path(urllib.request.url2pathname(parsed.path))
        entries.append((f"Flutter/Dart: {package['name']}", package_dir))

sections = ['Third-party notices for Xiaomi Lightbar Controller.\n']
for label, package_dir in sorted(entries):
    files = sorted({*package_dir.glob('LICENSE*'), *package_dir.glob('COPYING*')})
    files = [file for file in files if file.is_file()]
    if not files:
        continue
    sections.append('\n' + '=' * 72 + '\n' + label + '\n')
    for file in files:
        sections.append(f'\n--- {file.name} ---\n')
        sections.append(file.read_text(encoding='utf-8', errors='replace'))
        sections.append('\n')

upstream = root / 'THIRD_PARTY_LICENSES' / 'lightbar2mqtt.txt'
sections.append('\n' + '=' * 72 + '\nFirmware protocol reference: lightbar2mqtt\n')
sections.append(upstream.read_text(encoding='utf-8'))
font_license = root / 'desktop' / 'assets' / 'fonts' / 'OFL.txt'
sections.append('\n' + '=' * 72 + '\nNoto Sans SC font\n')
sections.append(font_license.read_text(encoding='utf-8'))
out.write_text(''.join(sections), encoding='utf-8')
