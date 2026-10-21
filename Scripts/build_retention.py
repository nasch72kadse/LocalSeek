#!/usr/bin/env python3
"""Bound local package and test history without touching compiler/download caches."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = re.compile(r'LocalSeek-(?:\d+\.\d+\.\d+-)?\d{8}-\d{6}(?:-[A-Za-z0-9]+)?')
RESULT = re.compile(r'(?:release-tests-[a-f0-9]+|early-release(?:-signed)?-tests)\.xcresult')
STATE = '.retention.json'
ACTIVE = '.build-active'


def container(root, name):
    root = Path(root).resolve()
    build = root / 'build'
    path = build / name
    if build.is_symlink() or path.is_symlink():
        raise ValueError('Refusing cleanup through a symlink: ' + str(path))
    return path


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def live_process(value):
    if type(value) is not int or value <= 1:
        return False
    try:
        os.kill(value, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def package_active(path):
    try:
        return live_process(int((path / ACTIVE).read_text().strip()))
    except (OSError, ValueError):
        return False


def regular_file(path):
    return not path.is_symlink() and path.is_file()


def package_info(path):
    """Only a verified package, or a checksum-verified legacy archive, is complete."""
    state = read_json(path / STATE)
    if isinstance(state, dict) and isinstance(state.get('artifact'), str):
        name = state['artifact']
        if (Path(name).name == name and re.fullmatch(r'LocalSeek-[0-9.]+-arm64\.dmg', name)
                and regular_file(path / name) and (path / name).stat().st_size > 0):
            # Artifact time remains stable when cleanup updates the state file.
            return path / name, state.get('finalized') is True
        return None
    # Older releases did not write a completion marker. Their archive checksum
    # was written only after signing/package/offline verification by the publisher.
    for checksum in path.glob('LocalSeek-*-arm64.dmg.sha256'):
        artifact = checksum.with_suffix('')
        if not regular_file(checksum) or not regular_file(artifact):
            continue
        fields = checksum.read_text().strip().split()
        if len(fields) != 2 or fields[1] != artifact.name or not re.fullmatch(r'[a-f0-9]{64}', fields[0]):
            continue
        digest = hashlib.sha256()
        with artifact.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        if digest.hexdigest() == fields[0]:
            return artifact, True
    return None


def referenced_package(packages, pointer):
    try:
        target = Path(pointer.read_text().strip())
        if target.is_absolute() and target.parent.parent == packages:
            return target.parent
    except OSError:
        pass
    return None


def remove(path, apply, removed):
    removed.append(path)
    if apply:
        # rmtree unlinks internal symlinks instead of traversing their targets.
        if path.is_symlink() or not path.is_dir():
            path.unlink()
        else:
            shutil.rmtree(path)


def cleanup_packages(root, apply=False, now=None):
    packages = container(root, 'packages')
    if not packages.is_dir():
        return []
    now = time.time() if now is None else now
    protected = {referenced_package(packages, packages.parent / name)
                 for name in ('latest-package.txt', 'latest-artifact.txt')}
    complete, incomplete, active = [], [], set()
    for path in packages.iterdir():
        if path.is_symlink() or not path.is_dir() or not PACKAGE.fullmatch(path.name):
            continue
        if package_active(path):
            active.add(path)
            continue
        info = package_info(path)
        if info:
            complete.append((path, *info))
        else:
            incomplete.append(path)
    complete.sort(key=lambda entry: (entry[1].stat().st_mtime_ns, entry[0].name), reverse=True)
    keep = protected | active | {entry[0] for entry in complete[:2]}
    removed = []
    for path, artifact, finalized in complete:
        if path not in keep:
            remove(path, apply, removed)
        elif finalized:
            for name in ('DiskImage', 'LocalSeek.zip', 'LocalSeek-notarized.zip'):
                child = path / name
                if child.exists() or child.is_symlink():
                    remove(child, apply, removed)
    # Recent failed builds are useful for diagnosis; never delete an active one.
    for path in incomplete:
        if path not in keep and now - path.stat().st_mtime > 86400:
            remove(path, apply, removed)
    return removed


def cleanup_reports(root, apply=False):
    reports = container(root, 'reports')
    if not reports.is_dir():
        return []
    protected, removed = set(), []
    receipt = read_json(reports / 'release-tests.json')
    if isinstance(receipt, dict) and isinstance(receipt.get('resultBundle'), str):
        bundle = Path(receipt['resultBundle'])
        if bundle.parent == reports:
            protected.add(bundle)
    for marker in reports.glob('.active-test-*.json'):
        if not regular_file(marker):
            continue
        info = read_json(marker)
        if isinstance(info, dict) and live_process(info.get('pid')):
            name = info.get('bundle')
            if isinstance(name, str) and RESULT.fullmatch(name):
                protected.add(reports / name)
        else:
            remove(marker, apply, removed)
    bundles = [p for p in reports.iterdir() if not p.is_symlink() and p.is_dir() and RESULT.fullmatch(p.name)]
    bundles.sort(key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
    protected.update(bundles[:3])
    for bundle in bundles:
        if bundle not in protected:
            remove(bundle, apply, removed)
    return removed


def automatic_cleanup(root, reports_only=False):
    """Housekeeping failure must not misreport a successful test or publication."""
    try:
        removed = cleanup_reports(root, apply=True)
        if not reports_only:
            removed += cleanup_packages(root, apply=True)
        if removed:
            print(f'Build cleanup: removed {len(removed)} obsolete paths.', flush=True)
    except (OSError, ValueError) as error:
        print('Build cleanup could not finish: ' + str(error), file=sys.stderr)


def record_package(root, package, awaiting_publication=False):
    packages = container(root, 'packages')
    package = Path(package).absolute()
    if package.parent != packages or package.is_symlink() or not PACKAGE.fullmatch(package.name):
        raise ValueError('Expected a timestamped local package directory.')
    artifacts = [p for p in package.glob('LocalSeek-*-arm64.dmg') if regular_file(p) and p.stat().st_size > 0]
    if len(artifacts) != 1:
        raise ValueError('Expected one verified DMG in the completed package.')
    state = dict(artifact=artifacts[0].name, finalized=not awaiting_publication)
    pending = package / (STATE + '.pending')
    if pending.is_symlink() or (package / STATE).is_symlink():
        raise ValueError('Refusing a symlinked completion marker.')
    pending.write_text(json.dumps(state) + '\n')
    pending.replace(package / STATE)


@contextmanager
def active_test_bundle(root, bundle):
    reports = container(root, 'reports')
    marker = reports / ('.active-test-' + bundle.stem + '.json')
    marker.write_text(json.dumps(dict(pid=os.getpid(), bundle=bundle.name)))
    try:
        yield
    finally:
        marker.unlink(missing_ok=True)
        automatic_cleanup(root, reports_only=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Delete the listed obsolete local files; default is preview only')
    parser.add_argument('--record-package', type=Path, help='Record a package only after its DMG verification succeeded')
    parser.add_argument('--awaiting-publication', action='store_true', help='Keep ZIP/staging files until publication succeeds')
    args = parser.parse_args()
    if args.awaiting_publication and not args.record_package:
        parser.error('--awaiting-publication requires --record-package')
    try:
        if args.record_package:
            if not args.apply:
                parser.error('--record-package requires --apply')
            record_package(ROOT, args.record_package, args.awaiting_publication)
        removed = cleanup_reports(ROOT, apply=args.apply) + cleanup_packages(ROOT, apply=args.apply)
        for path in removed:
            print(('Removed: ' if args.apply else 'Would remove: ') + str(path.relative_to(ROOT)))
        print(('Cleanup complete' if args.apply else 'Preview only') + f': {len(removed)} obsolete paths.')
        return 0
    except (OSError, ValueError) as error:
        print('Build cleanup failed: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
