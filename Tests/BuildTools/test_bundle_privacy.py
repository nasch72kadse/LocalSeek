import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('bundle_privacy', ROOT / 'Scripts/check-bundle-privacy.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class BundlePrivacyTests(unittest.TestCase):
    def make_app(self, root):
        app = root / 'LocalSeek.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/LocalSeek').write_bytes(b'\x00binary fixture\x00')
        return app

    def test_embedded_home_paths_are_rejected_without_logging_the_value(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app(root)
            binary = app / 'Contents/MacOS/LocalSeek'
            binary.write_bytes(b'\x00' + b'/Users/' + b'private-test-user/source.cpp\x00')
            result = subprocess.run(['python3', str(ROOT / 'Scripts/check-bundle-privacy.py'), str(app)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Contents/MacOS/LocalSeek', result.stderr)
            self.assertNotIn('private-test-user', result.stdout + result.stderr)

    def test_credentials_index_and_resource_build_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app(root)
            resources = app / 'Contents/Resources'
            resources.mkdir()
            for name in ('.env.local', 'private.p12', 'index.sqlite-wal'):
                (resources / name).write_bytes(b'fixture')
            (resources / 'INSTALLATION.md').write_text(str(root / 'source/file.cpp'))
            (resources / 'embedded.txt').write_bytes(b'-----BEGIN PRIVATE KEY-----\nfixture')
            findings = privacy.inspect(app, build_root=root)
            self.assertEqual(len(findings), 5)

    def test_neutral_paths_and_public_certificate_are_allowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary))
            resources = app / 'Contents/Resources'
            resources.mkdir()
            (resources / 'INSTALLATION.md').write_text('~/Applications/LocalSeek.app\n/LocalSeek/source.cpp')
            (resources / 'certificate.der').write_bytes(b'-----BEGIN CERTIFICATE-----\npublic fixture')
            (resources / 'readme-link').symlink_to(resources / 'INSTALLATION.md')
            self.assertEqual(privacy.inspect(app), [])

    def test_native_build_flags_remove_compiled_source_paths_even_with_spaces(self):
        # Exercise build-native.sh's real argument quoting, then compile using the
        # captured CMake flags. No model download or full llama.cpp build needed.
        with tempfile.TemporaryDirectory(prefix='native privacy ') as temporary:
            root = Path(temporary).resolve()
            (root / 'Scripts').mkdir()
            shutil.copyfile(ROOT / 'Scripts/build-native.sh', root / 'Scripts/build-native.sh')
            (root / 'build/Dependencies/llama.cpp/.git').mkdir(parents=True)
            pin = re.search(r'^PIN=([a-f0-9]+)$', (root / 'Scripts/build-native.sh').read_text(), re.M)[1]
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            cmake = bin_dir / 'cmake'
            cmake.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                             'with open(os.environ["CAPTURE"], "a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
            cmake.chmod(0o755)
            git = bin_dir / 'git'
            git.write_text('#!/bin/sh\nprintf "%s\\n" "' + pin + '"\n')
            git.chmod(0o755)
            capture = root / 'cmake-arguments.jsonl'
            env = os.environ | {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'], 'CAPTURE': str(capture)}
            subprocess.run(['bash', 'Scripts/build-native.sh'], cwd=root, env=env,
                           capture_output=True, text=True, check=True)
            arguments = json.loads(capture.read_text().splitlines()[0])
            source = root / 'fixture.cpp'
            source.write_text('const char *source_file = __FILE__;\n')
            for language in ('C', 'CXX'):
                value = next(arg.split('=', 1)[1] for arg in arguments if arg.startswith('-DCMAKE_' + language + '_FLAGS='))
                output = root / (language + '.o')
                subprocess.run(['xcrun', 'clang++', *shlex.split(value), '-c', str(source), '-o', str(output)],
                               capture_output=True, text=True, check=True)
                binary = output.read_bytes()
                self.assertNotIn(str(root).encode(), binary)
                self.assertIn(b'/LocalSeek/fixture.cpp', binary)


if __name__ == '__main__':
    unittest.main()
