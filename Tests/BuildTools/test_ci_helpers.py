import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class CIHelperTests(unittest.TestCase):
    def test_pruning_keeps_latest_branch_downloads_and_unrelated_artifacts(self):
        entries = [
            dict(id=i, name=f'LocalSeek-main-{i}-1', created_at=f'2026-10-{i:02}T12:00:00Z', expired=False)
            for i in (1, 2, 3)
        ] + [
            dict(id=4, name='LocalSeek-dev-4-1', created_at='2026-10-04T12:00:00Z', expired=False),
            dict(id=5, name='Other-project', created_at='2026-10-01T12:00:00Z', expired=False),
            dict(id=6, name='LocalSeek-dev-6-1', created_at='2026-10-06T12:00:00Z', expired=True),
        ]
        # gh emits pretty JSON objects separated by whitespace, not one JSON array.
        response = '\n'.join(json.dumps(entry, indent=2) for entry in entries)
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/LocalSeek'}), \
             patch('subprocess.check_output', return_value=response), \
             patch('subprocess.run') as remove, contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(ROOT / 'Scripts/ci/prune-artifacts.py'))
        deleted = {call.args[0][-1].rsplit('/', 1)[1] for call in remove.call_args_list}
        self.assertEqual(deleted, {'1', '2', '6'})

    def test_partial_signing_configuration_fails_before_keychain_access(self):
        environment = {key: value for key, value in os.environ.items() if not key.startswith('APPLE_')}
        environment['APPLE_ID'] = 'test@example.invalid'
        result = subprocess.run(['bash', 'Scripts/ci/prepare-signing.sh'], cwd=ROOT,
                                env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APPLE_CERTIFICATE_P12_BASE64', result.stderr)
        self.assertNotIn('test@example.invalid', result.stdout + result.stderr)

    def test_cached_model_is_verified_and_exported_without_downloading(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'Scripts/ci').mkdir(parents=True)
            (root / 'Models').mkdir()
            (root / 'build/ci-model').mkdir(parents=True)
            shutil.copyfile(ROOT / 'Scripts/ci/prepare-model.sh', root / 'Scripts/ci/prepare-model.sh')
            data = b'synthetic pinned model fixture'
            (root / 'build/ci-model/fixture.gguf').write_bytes(data)
            (root / 'Models/manifest.json').write_text(json.dumps(dict(
                name='fixture.gguf', sha256=hashlib.sha256(data).hexdigest(),
                download='https://example.invalid/should-not-be-requested')))
            (root / 'bin').mkdir()
            curl = root / 'bin/curl'
            curl.write_text('#!/bin/bash\necho unexpected-download >&2\nexit 99\n')
            curl.chmod(0o755)
            environment = os.environ | {'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                                        'GITHUB_ENV': str(root / 'exports')}
            subprocess.run(['bash', 'Scripts/ci/prepare-model.sh'], cwd=root, env=environment,
                           capture_output=True, text=True, check=True)
            exports = (root / 'exports').read_text()
            self.assertIn('LOCALSEEK_MODEL=' + str(root / 'build/ci-model/fixture.gguf'), exports)
            self.assertIn('LOCALSEEK_TEST_MODEL=', exports)


if __name__ == '__main__':
    unittest.main()
