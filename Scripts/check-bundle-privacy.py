#!/usr/bin/env python3
"""Reject private build paths and credential/index files in a distributable app."""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HOME_PATH = re.compile(rb'/(?:Users|home)/[^/\s\x00"<>]+/')
PRIVATE_SUFFIXES = {'.p12', '.p8', '.pem', '.key', '.sqlite', '.sqlite-wal',
                    '.sqlite-shm', '.keychain', '.keychain-db', '.mobileprovision',
                    '.provisionprofile'}


def inspect(app, build_root=ROOT):
    """Return relative filenames and categories; never print the private values."""
    app = Path(app)
    if not (app / 'Contents/MacOS/LocalSeek').is_file():
        raise ValueError('Kein vollständiges LocalSeek-App-Bundle.')
    findings = []
    root_prefixes = {str(Path(build_root).absolute()).encode() + b'/',
                     str(Path(build_root).resolve()).encode() + b'/'}
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        relative = str(path.relative_to(app))
        name = path.name.lower()
        if name == '.env' or name.startswith('.env.') or any(name.endswith(s) for s in PRIVATE_SUFFIXES):
            findings.append((relative, 'Zugangsdaten-/Indexdatei'))
        # The public model is verified against its pinned digest by verify-bundle.sh.
        if path.suffix == '.gguf':
            continue
        content = path.read_bytes()
        if HOME_PATH.search(content) or any(prefix in content for prefix in root_prefixes):
            findings.append((relative, 'absoluter Benutzer-/Build-Pfad'))
        if re.search(rb'-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----', content):
            findings.append((relative, 'privater Schlüssel'))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        findings = inspect(args.app)
    except (OSError, ValueError) as error:
        print(f'Paket-Datenschutzprüfung nicht ausführbar: {error}', file=sys.stderr)
        return 1
    for filename, category in findings:
        print(f'Paket-Datenschutzprüfung: {category} in {filename}', file=sys.stderr)
    if findings:
        return 1
    print('Paket-Datenschutzprüfung erfolgreich.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
