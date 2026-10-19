import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('local_release', ROOT / 'Scripts/publish-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = 'a' * 40
IDENTITY = 'b' * 40
TEAM = 'AB12345678'
IDENTITIES = f'  1) {IDENTITY} "Developer ID Application: Example ({TEAM})"\n'


class LocalReleaseTests(unittest.TestCase):
    def environment(self):
        return {'LOCALSEEK_SIGN_IDENTITY': IDENTITY, 'LOCALSEEK_NOTARY_PROFILE': 'LocalSeek'}

    def preflight_run(self, *args, **kwargs):
        if args[0] == 'security':
            return IDENTITIES
        if args[:3] == ('git', 'branch', '--show-current'):
            return 'main'
        if args[:3] == ('git', 'rev-parse', 'HEAD') or any('/commits/' in arg for arg in args):
            return SHA
        return ''

    def test_unsigned_and_wrong_certificate_stop_before_upload(self):
        for identity in ('-', '', 'Apple Development: Example'):
            with self.subTest(identity=identity), patch.dict(os.environ,
                    self.environment() | {'LOCALSEEK_SIGN_IDENTITY': identity}, clear=True), \
                    patch.object(release, 'run', side_effect=self.preflight_run) as command:
                with self.assertRaises(RuntimeError):
                    release.preflight()
                self.assertFalse(any(call.args[0] == 'gh' for call in command.call_args_list))

    def test_missing_notary_profile_stops_before_release(self):
        def command(*args, **kwargs):
            if args[:3] == ('xcrun', 'notarytool', 'history'):
                raise RuntimeError('Missing keychain item')
            return self.preflight_run(*args, **kwargs)
        with patch.dict(os.environ, self.environment(), clear=True), \
                patch.object(release, 'run', side_effect=command) as called:
            with self.assertRaisesRegex(RuntimeError, 'Missing keychain'):
                release.preflight()
            self.assertFalse(any(call.args[0] == 'git' for call in called.call_args_list))

    def test_main_dev_tags_and_existing_tag_rejection(self):
        for branch in ('main', 'dev'):
            def command(*args, **kwargs):
                if args[:3] == ('git', 'branch', '--show-current'):
                    return branch
                return self.preflight_run(*args, **kwargs)
            with self.subTest(branch=branch), patch.dict(os.environ, self.environment(), clear=True), \
                    patch.object(release, 'run', side_effect=command), \
                    patch.object(Path, 'read_text', return_value='  MARKETING_VERSION: "1.2.3"\n'):
                plan = release.preflight()
                expected = 'v1.2.3' if branch == 'main' else 'v1.2.3-dev.' + SHA[:12]
                self.assertEqual(plan['tag'], expected)
                self.assertEqual(plan['team'], TEAM)
        def existing(*args, **kwargs):
            if any('/git/matching-refs/' in arg for arg in args):
                return 'refs/tags/v1.2.3\nrefs/tags/v1.2.3-extra'
            return self.preflight_run(*args, **kwargs)
        with patch.dict(os.environ, self.environment(), clear=True), \
                patch.object(release, 'run', side_effect=existing), \
                patch.object(Path, 'read_text', return_value='  MARKETING_VERSION: "1.2.3"\n'):
            with self.assertRaisesRegex(RuntimeError, 'existiert bereits'):
                release.preflight()

    def test_dirty_or_changed_commit_cannot_be_published(self):
        for dirty, built in ((True, SHA), (False, 'c' * 40)):
            def command(*args, **kwargs):
                if args[:3] == ('git', 'status', '--porcelain') and dirty:
                    return ' M Apps/example.swift'
                return self.preflight_run(*args, **kwargs)
            with self.subTest(dirty=dirty), patch.dict(os.environ,
                    self.environment() | {'LOCALSEEK_BUILT_COMMIT': built}, clear=True), \
                    patch.object(release, 'run', side_effect=command):
                with self.assertRaises(RuntimeError):
                    release.preflight()

    def test_signature_requires_team_timestamp_runtime_and_stapled_ticket(self):
        good = f'Authority=Developer ID Application: Example ({TEAM})\nTeamIdentifier={TEAM}\nTimestamp=now\nflags=0x10000(runtime)\n'
        for details in (good.replace('Developer ID Application:', 'Apple Development:'),
                        good.replace(TEAM, 'ZZ12345678'), good.replace('Timestamp=', 'NoTimestamp='),
                        good.replace('flags=0x10000(runtime)', 'flags=0x2(adhoc)')):
            with self.subTest(details=details), patch.object(release, 'run'), \
                    patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess(
                        [], 0, '', details)):
                with self.assertRaises(RuntimeError):
                    release.verify_signing(Path('app'), TEAM, runtime=True)
        with patch.object(release, 'run') as command, patch.object(release.subprocess, 'run',
                return_value=subprocess.CompletedProcess([], 0, '', good)):
            release.verify_signing(Path('app'), TEAM, runtime=True)
            command.assert_any_call('xcrun', 'stapler', 'validate', 'app')

    def test_upload_only_follows_all_checks_and_targets_exact_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'build/packages/fixture'
            app = package / 'LocalSeek.app'
            app.mkdir(parents=True)
            dmg = package / 'LocalSeek-1.1.0-arm64.dmg'
            dmg.write_bytes(b'synthetic image')
            build = root / 'build'
            (build / 'latest-package.txt').write_text(str(app))
            (build / 'latest-artifact.txt').write_text(str(dmg))
            (build / 'last-built-configuration.txt').write_text('Release')
            (build / 'source-checksums.txt').write_text('receipt\n')
            plan = dict(repository='owner/LocalSeek', commit=SHA, branch='dev', version='1.1.0',
                        tag='v1.1.0-dev.' + SHA[:12], team=TEAM)
            for failure in ('notary', 'offline', None):
                calls = []
                def command(*args, **kwargs):
                    calls.append(args)
                    if args[:2] == ('plutil', '-extract'):
                        return '1.1.0'
                    if args[:2] == ('bash', 'Scripts/source-checksums.sh'):
                        return 'receipt'
                    if failure == 'offline' and args[:2] == ('bash', 'Scripts/verify-offline.sh'):
                        raise RuntimeError('Offline test failed')
                    return ''
                with self.subTest(failure=failure), patch.object(release, 'ROOT', root), \
                        patch.object(release, 'run', side_effect=command), \
                        patch.object(release, 'verify_signing',
                            side_effect=RuntimeError('Notary validation failed') if failure == 'notary' else None):
                    if failure:
                        with self.assertRaises(RuntimeError):
                            release.publish(plan)
                        self.assertFalse(any(call[0] == 'gh' for call in calls))
                    else:
                        with contextlib.redirect_stdout(io.StringIO()):
                            release.publish(plan)
                        tag_create, upload = [call for call in calls if call[0] == 'gh']
                        self.assertIn('sha=' + SHA, tag_create)
                        self.assertIn('ref=refs/tags/' + plan['tag'], tag_create)
                        self.assertIn('--verify-tag', upload)
                        self.assertIn('--prerelease', upload)
                        self.assertIn('--latest=false', upload)
                        self.assertEqual(upload[upload.index('--target') + 1], SHA)
                        self.assertNotIn('--clobber', upload)
                        self.assertTrue(dmg.with_suffix('.dmg.sha256').read_text().endswith('  ' + dmg.name + '\n'))

    def test_ci_never_loads_local_build_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.env.local').write_text('LOCALSEEK_PUBLISH_RELEASE=1\n')
            command = ['bash', '-c', 'source "$1"; printf "%s" "$LOCALSEEK_PUBLISH_RELEASE"',
                       'test', str(ROOT / 'Scripts/local-build-config.sh')]
            for ci, expected in (('true', '0'), ('false', '1')):
                result = subprocess.run(command, cwd=root, env={'GITHUB_ACTIONS': ci, 'PATH': os.environ['PATH']},
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, expected)


if __name__ == '__main__':
    unittest.main()
