#!/usr/bin/env python3
"""Validate the updater configuration and every embedded Sparkle executable."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from update_feed import FEED_URL, PUBLIC_KEY


def verify_settings(settings):
    expected = dict(SUFeedURL=FEED_URL, SUPublicEDKey=PUBLIC_KEY,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                    SUEnableSystemProfiling=False)
    for key, value in expected.items():
        if settings.get(key) != value:
            raise RuntimeError(f'Unexpected updater setting: {key}')
    if settings.get('LocalSeekUpdateChannel') not in ('stable', 'dev'):
        raise RuntimeError('Missing update channel')


def verify(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        verify_settings(plistlib.load(source))
    framework = app / 'Contents/Frameworks/Sparkle.framework/Versions/B'
    signature = subprocess.run(['codesign', '-d', '--verbose=2', str(app)],
                               capture_output=True, text=True, check=True).stderr
    team = None
    if 'Authority=Developer ID Application:' in signature:
        match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signature, re.M)
        if not match:
            raise RuntimeError('Missing app signing team')
        team = match[1]
    for relative in ('Sparkle', 'Autoupdate', 'Updater.app/Contents/MacOS/Updater',
                     'XPCServices/Installer.xpc/Contents/MacOS/Installer',
                     'XPCServices/Downloader.xpc/Contents/MacOS/Downloader'):
        binary = framework / relative
        if not binary.is_file():
            raise RuntimeError(f'Missing Sparkle executable: {relative}')
        architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        if 'arm64' not in architectures:
            raise RuntimeError(f'Sparkle executable has no Apple Silicon slice: {relative}')
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
        if team:
            details = subprocess.run(['codesign', '-d', '--verbose=2', str(binary)],
                                     capture_output=True, text=True, check=True).stderr
            if (f'TeamIdentifier={team}' not in details.splitlines() or
                    'Authority=Developer ID Application:' not in details or
                    not re.search(r'^Timestamp=(?!none$).+$', details, re.M) or
                    not re.search(r'flags=.*\bruntime\b', details)):
                raise RuntimeError(f'Sparkle helper must have the app team, timestamp, and Hardened Runtime: {relative}')
        dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True)
        for line in dependencies.splitlines()[1:]:
            if not line.startswith('\t'):
                continue  # otool repeats a heading for every universal slice.
            dependency = line.strip().split(' ', 1)[0]
            if not dependency.startswith(('/System/Library/', '/usr/lib/')):
                if dependency != '@rpath/Sparkle.framework/Versions/B/Sparkle':
                    raise RuntimeError(f'External Sparkle dependency: {dependency}')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Updater bundle verification failed: {error}')
