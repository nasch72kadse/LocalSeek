#!/usr/bin/env python3
"""Publish a locally signed and notarized DMG; never overwrite a tag or release."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, visible=False):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=not visible)
    if result.returncode:
        detail = '' if visible else (result.stderr or result.stdout).strip()
        raise RuntimeError(f'{args[0]} fehlgeschlagen' + (f': {detail}' if detail else ''))
    return '' if visible else result.stdout.strip()


def preflight():
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        raise RuntimeError('Dieser Release-Weg ist für den lokalen Mac vorgesehen.')
    identity = os.environ.get('LOCALSEEK_SIGN_IDENTITY', '')
    profile = os.environ.get('LOCALSEEK_NOTARY_PROFILE', '')
    if not identity or identity == '-' or not profile:
        raise RuntimeError('Developer-ID-Signieridentität und Notarisierungsprofil fehlen. '
                           'LOCALSEEK_SIGN_IDENTITY und LOCALSEEK_NOTARY_PROFILE setzen.')
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning')
    matches = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(Developer ID Application: .+ \(([A-Z0-9]{10})\))"',
                         identities, re.M)
    selected = [entry for entry in matches if identity.lower() == entry[0].lower() or identity == entry[1]]
    if len(selected) != 1:
        raise RuntimeError('Die konfigurierte gültige Developer-ID-Application-Identität '
                           'mit privatem Schlüssel ist nicht im Schlüsselbund verfügbar.')
    team = selected[0][2]
    run('gh', 'auth', 'status', '--hostname', 'github.com')
    notary_args = ['--keychain-profile', profile]
    if os.environ.get('LOCALSEEK_NOTARY_KEYCHAIN'):
        notary_args += ['--keychain', os.environ['LOCALSEEK_NOTARY_KEYCHAIN']]
    # Read-only: validates the stored credentials without exposing submission history.
    run('xcrun', 'notarytool', 'history', *notary_args, '--output-format', 'json')
    if run('git', 'status', '--porcelain', '--untracked-files=normal'):
        raise RuntimeError('Release benötigt einen sauberen, committeten Quellstand. '
                           'Lokale Einstellungen gehören in die ignorierte .env.local.')
    branch = run('git', 'branch', '--show-current')
    if branch not in ('main', 'dev'):
        raise RuntimeError('Lokale Releases werden von main oder dev erstellt.')
    commit = run('git', 'rev-parse', 'HEAD')
    if os.environ.get('LOCALSEEK_BUILT_COMMIT', commit) != commit:
        raise RuntimeError('Der Git-Commit hat sich während des Builds geändert; erneut bauen.')
    repository = os.environ.get('LOCALSEEK_RELEASE_REPOSITORY', 'nasch72kadse/LocalSeek')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise RuntimeError('Ungültiges GitHub-Repository.')
    remote_commit = run('gh', 'api', '--hostname', 'github.com', f'repos/{repository}/commits/{commit}', '--jq', '.sha')
    if remote_commit != commit:
        raise RuntimeError('Quellcommit fehlt auf GitHub. Erst den Quellstand pushen.')
    version_match = re.findall(r'^\s+MARKETING_VERSION:\s*"?(\d+\.\d+\.\d+)"?\s*$',
                               (ROOT / 'project.yml').read_text(), re.M)
    if len(version_match) != 1:
        raise RuntimeError('Eindeutige MARKETING_VERSION im Format X.Y.Z erforderlich.')
    version = version_match[0]
    tag = os.environ.get('LOCALSEEK_RELEASE_TAG') or (
        f'v{version}' if branch == 'main' else f'v{version}-dev.{commit[:12]}')
    if not re.fullmatch(r'v[0-9][A-Za-z0-9._-]*', tag):
        raise RuntimeError('Release-Tag muss mit v und einer Ziffer beginnen und darf nur Buchstaben, '
                           'Ziffern, Punkt, Unterstrich oder Bindestrich enthalten.')
    run('git', 'check-ref-format', 'refs/tags/' + tag)
    refs = run('gh', 'api', '--hostname', 'github.com', '--paginate',
               f'repos/{repository}/git/matching-refs/tags/{tag}', '--jq', '.[].ref')
    if 'refs/tags/' + tag in refs.splitlines():
        raise RuntimeError(f'Tag {tag} existiert bereits. Version oder LOCALSEEK_RELEASE_TAG erhöhen; '
                           'bestehende Releases werden nicht überschrieben.')
    return dict(repository=repository, commit=commit, branch=branch, version=version, tag=tag, team=team)


def verify_signing(path, team, runtime=False):
    run('codesign', '--verify', '--deep', '--strict', str(path))
    # codesign writes signature metadata to stderr even on success.
    result = subprocess.run(['codesign', '-d', '--verbose=2', str(path)], cwd=ROOT,
                            text=True, capture_output=True, check=True)
    details = result.stdout + result.stderr
    if (not re.search(r'^Authority=Developer ID Application:.+$', details, re.M) or
            f'TeamIdentifier={team}' not in details.splitlines() or
            not re.search(r'^Timestamp=(?!none$).+$', details, re.M)):
        raise RuntimeError('Paket besitzt keine zeitgestempelte Developer-ID-Signatur des konfigurierten Teams.')
    if runtime and not re.search(r'flags=.*\bruntime\b', details):
        raise RuntimeError('Hardened Runtime fehlt in der App-Signatur.')
    run('xcrun', 'stapler', 'validate', str(path))


def publish(plan):
    # Also enforce the gate for direct/manual publishing of an existing package.
    run('bash', 'Scripts/test-release.sh', '--verify')
    build = ROOT / 'build'
    app = Path((build / 'latest-package.txt').read_text().strip()).resolve()
    dmg = Path((build / 'latest-artifact.txt').read_text().strip()).resolve()
    packages = (build / 'packages').resolve()
    if (packages not in app.parents or app.parent != dmg.parent or
            app.name != 'LocalSeek.app' or dmg.name != f"LocalSeek-{plan['version']}-arm64.dmg"):
        raise RuntimeError('App und DMG müssen aus demselben aktuellen Versionspaket stammen.')
    if (build / 'last-built-configuration.txt').read_text().strip() != 'Release':
        raise RuntimeError('Nur Release-Builds können veröffentlicht werden.')
    receipt = run('bash', 'Scripts/source-checksums.sh')
    if receipt != (build / 'source-checksums.txt').read_text().strip():
        raise RuntimeError('Quellstand hat sich seit dem Build geändert; erneut bauen.')
    version = run('plutil', '-extract', 'CFBundleShortVersionString', 'raw', str(app / 'Contents/Info.plist'))
    if version != plan['version']:
        raise RuntimeError('App-Version stimmt nicht mit dem Quellstand überein.')
    verify_signing(app, plan['team'], runtime=True)
    verify_signing(dmg, plan['team'])
    run('spctl', '--assess', '--type', 'execute', str(app))
    run('bash', 'Scripts/verify-artifact.sh', str(dmg), visible=True)
    run('bash', 'Scripts/verify-offline.sh', str(app), visible=True)
    checksum = dmg.with_suffix('.dmg.sha256')
    digest = hashlib.sha256()
    with dmg.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    checksum.write_text(digest.hexdigest() + '  ' + dmg.name + '\n')
    with tempfile.TemporaryDirectory(prefix='release-', dir=build) as temporary:
        notes = Path(temporary) / 'notes.md'
        notes.write_text(f"LocalSeek {plan['version']} für Apple Silicon, macOS 14 oder neuer.\n\n"
                         f"Commit: `{plan['commit']}`\n\n"
                         'Developer ID signiert und von Apple notariert. '
                         'DMG enthält Suchmodell, OCR-Helper und Laufzeitbibliotheken.\n')
        # Atomic tag creation fails if another publisher claimed the tag since
        # preflight. Never allow gh to reuse a tag pointing to another commit.
        run('gh', 'api', '--hostname', 'github.com', '--method', 'POST',
            f"repos/{plan['repository']}/git/refs", '-f', 'ref=refs/tags/' + plan['tag'],
            '-f', 'sha=' + plan['commit'])
        args = ['gh', 'release', 'create', plan['tag'], str(dmg), str(checksum),
                '--repo', 'github.com/' + plan['repository'], '--target', plan['commit'],
                '--verify-tag', '--title', 'LocalSeek ' + plan['tag'], '--notes-file', str(notes)]
        if plan['branch'] == 'dev':
            args += ['--prerelease', '--latest=false']
        else:
            args += ['--latest']
        # gh stages the release, uploads every asset, then publishes. No --clobber.
        run(*args, visible=True)
    print(f"Signiertes Release: https://github.com/{plan['repository']}/releases/tag/{plan['tag']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true', help='Voraussetzungen ohne Upload prüfen')
    mode.add_argument('--publish', action='store_true', help='Aktuelles signiertes Paket veröffentlichen')
    args = parser.parse_args()
    try:
        plan = preflight()
        if args.publish:
            publish(plan)
        else:
            print(f"Lokaler Release vorbereitet: {plan['repository']} {plan['tag']} ({plan['commit'][:12]})")
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'LocalSeek Release abgebrochen: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
