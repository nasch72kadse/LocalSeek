import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
import update_feed as feed


class UpdateFeedTests(unittest.TestCase):
    def plan(self, parent=None, content=None):
        return dict(repository=feed.REPOSITORY, branch='dev', build_number=6,
                    version='1.2.0', tag='v1.2.0-dev.abc',
                    feed=dict(parent=parent, content=content))

    def test_first_feed_and_missing_signing_key(self):
        def run(*args):
            if args[0].endswith('generate_keys'):
                return feed.PUBLIC_KEY
            return '[]'
        self.assertEqual(feed.preflight(ROOT, run, feed.REPOSITORY, 6), dict(parent=None, content=None))
        with self.assertRaisesRegex(RuntimeError, 'key is missing'):
            feed.preflight(ROOT, lambda *args: '', feed.REPOSITORY, 6)
        with self.assertRaisesRegex(RuntimeError, 'repository mismatch'):
            feed.preflight(ROOT, run, 'other/repo', 6)

    def test_existing_feed_must_be_authentic_and_build_number_increases(self):
        content = f'<rss><channel><item><sparkle:version xmlns:sparkle="{feed.NS}">7</sparkle:version></item></channel></rss>'
        def api(run, repository, suffix, payload=None):
            if suffix.startswith('git/matching'):
                return [dict(ref='refs/heads/updates', object=dict(sha='parent'))]
            if suffix == 'git/commits/parent':
                return dict(tree=dict(sha='tree'))
            if suffix == 'git/trees/tree':
                return dict(tree=[dict(path='appcast.xml', type='blob', sha='blob')])
            return dict(content=base64.b64encode(content.encode()).decode())
        def run(*args):
            return feed.PUBLIC_KEY if args[0].endswith('generate_keys') else ''
        with patch.object(feed, 'api', side_effect=api):
            for number in (6, 7):
                with self.assertRaisesRegex(RuntimeError, 'exceed published build 7'):
                    feed.preflight(ROOT, run, feed.REPOSITORY, number)
            self.assertEqual(feed.preflight(ROOT, run, feed.REPOSITORY, 8)['parent'], 'parent')
            def failed(*args):
                if '--verify' in args:
                    raise RuntimeError('Invalid feed signature')
                return run(*args)
            with self.assertRaisesRegex(RuntimeError, 'Invalid feed signature'):
                feed.preflight(ROOT, failed, feed.REPOSITORY, 8)

    def test_malformed_feed_is_not_silently_replaced(self):
        for content in ('oops', '<rss/>', '<rss><channel><item/></channel></rss>'):
            with self.subTest(content=content), self.assertRaises(RuntimeError):
                feed.parse_feed(content)

    def test_feed_preserves_stable_channel_and_targets_exact_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            info = root / 'LocalSeek.app/Contents/Info.plist'
            info.parent.mkdir(parents=True)
            settings = dict(SUFeedURL=feed.FEED_URL, SUPublicEDKey=feed.PUBLIC_KEY,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                CFBundleVersion='6', LocalSeekUpdateChannel='dev')
            info.write_bytes(plistlib.dumps(settings))
            archive = root / 'LocalSeek-1.2.0-arm64.dmg'
            archive.write_bytes(b'fixture')
            signature = base64.b64encode(b'x' * 64).decode()
            previous = f'<rss xmlns:sparkle="{feed.NS}"><channel><item><title>Stable</title><sparkle:version>5</sparkle:version></item></channel></rss>'
            calls = []
            def run(*args):
                calls.append(args)
                return signature if '-p' in args else ''
            output = feed.prepare(root, run, self.plan(content=previous), archive, root / 'appcast.xml')
            items = ET.parse(output).findall('channel/item')
            self.assertEqual(len(items), 2)
            self.assertEqual(items[0].findtext(f'{{{feed.NS}}}channel'), 'dev')
            self.assertIsNone(items[1].find(f'{{{feed.NS}}}channel'))
            enclosure = items[0].find('enclosure')
            self.assertEqual(enclosure.get('length'), '7')
            self.assertEqual(enclosure.get(f'{{{feed.NS}}}edSignature'), signature)
            self.assertIn('/v1.2.0-dev.abc/LocalSeek-1.2.0-arm64.dmg', enclosure.get('url'))
            self.assertTrue(any('--verify' in args and str(output) in args for args in calls))
            settings['SUPublicEDKey'] = 'wrong'
            info.write_bytes(plistlib.dumps(settings))
            with self.assertRaisesRegex(RuntimeError, 'configuration'):
                feed.prepare(root, run, self.plan(), archive, output)

    def test_feed_ref_changes_once_after_all_objects_and_rejects_concurrent_publisher(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'appcast.xml'
            path.write_text('signed fixture')
            calls = []
            def api(run, repository, suffix, payload=None):
                calls.append((suffix, payload))
                return dict(sha=suffix.rsplit('/', 1)[-1])
            def run(*args):
                self.assertEqual([item[0] for item in calls], ['git/blobs', 'git/trees', 'git/commits'])
                self.assertIn('force=false', args)
                raise RuntimeError('422 Reference update failed')
            with patch.object(feed, 'api', side_effect=api), self.assertRaisesRegex(RuntimeError, '422'):
                feed.publish(run, self.plan(parent='old'), path)
            commit = calls[-1][1]
            self.assertEqual(commit['parents'], ['old'])
            self.assertEqual(commit['author'], feed.BOT)

    def test_real_signatures_reject_modified_archives_and_feeds(self):
        # A temporary test key never reads or changes the production Keychain.
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            source = path / 'key.swift'
            source.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
''')
            key = path / 'private-key'
            subprocess.run(['xcrun', 'swift', str(source), str(key)], check=True, capture_output=True)
            sign = [feed.tool(ROOT, 'sign_update'), '--ed-key-file', str(key)]
            archive = path / 'fixture.dmg'
            archive.write_bytes(b'Authentic local test payload')
            signature = subprocess.check_output(sign + ['-p', str(archive)], text=True).strip()
            subprocess.run(sign + ['--verify', str(archive), signature], check=True, capture_output=True)
            archive.write_bytes(b'Modified local test payload')
            self.assertNotEqual(subprocess.run(sign + ['--verify', str(archive), signature], capture_output=True).returncode, 0)
            appcast = path / 'appcast.xml'
            appcast.write_text('<rss version="2.0"><channel><title>LocalSeek</title></channel></rss>')
            subprocess.run(sign + [str(appcast)], check=True, capture_output=True)
            subprocess.run(sign + ['--verify', str(appcast)], check=True, capture_output=True)
            appcast.write_bytes(appcast.read_bytes().replace(b'LocalSeek', b'OtherSeek'))
            self.assertNotEqual(subprocess.run(sign + ['--verify', str(appcast)], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
