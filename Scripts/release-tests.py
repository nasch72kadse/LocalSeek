#!/usr/bin/env python3
"""Run release checks before uploads and bind successful results to their inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build/reports'
RECEIPT = REPORTS / 'release-tests.json'


def output(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def inputs():
    return dict(commit=output('git', 'rev-parse', 'HEAD'),
                sourceSHA256=hashlib.sha256(output('bash', 'Scripts/source-checksums.sh').encode()).hexdigest(),
                macOS=platform.mac_ver()[0], xcode=output('xcodebuild', '-version'))


def verify():
    receipt = json.loads(RECEIPT.read_text())
    if receipt.get('inputs') != inputs() or not 0 <= time.time() - receipt.get('completedAt', 0) <= 86400:
        raise RuntimeError('Testergebnis ist veraltet oder gehört zu einem anderen Quellstand/System.')
    if (receipt.get('passedTests', 0) <= 0 or receipt.get('failedTests') != 0 or
            receipt.get('skippedTests') != 0 or receipt.get('toolTests', 0) <= 0):
        raise RuntimeError('Vollständig bestandene Unit- und Integrationstests sind erforderlich.')
    return receipt


def passed_swift_tests(summary):
    if (summary.get('result') != 'Passed' or summary.get('totalTestCount', 0) <= 0 or
            summary.get('passedTests') != summary.get('totalTestCount') or
            summary.get('failedTests') != 0 or summary.get('skippedTests') != 0 or
            summary.get('expectedFailures') != 0):
        raise RuntimeError('Nicht alle Swift-Tests wurden erfolgreich ausgeführt; siehe test-summary.json.')
    return summary['passedTests']


def logged(args, name, environment=None, timeout=900):
    path = REPORTS / name
    print('Prüfung: ' + name, flush=True)
    with path.open('w') as log:
        process = subprocess.Popen(args, cwd=ROOT, env=environment, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise RuntimeError('Testlauf abgebrochen oder Zeitlimit erreicht; siehe ' + str(path))
    if status:
        raise RuntimeError('Testlauf fehlgeschlagen; siehe ' + str(path))
    return path


def run_tests():
    REPORTS.mkdir(parents=True, exist_ok=True)
    # A failed rerun must never leave a previous successful receipt usable.
    RECEIPT.unlink(missing_ok=True)
    before = inputs()
    logged(["bash", "Scripts/sparkle-tools.sh"], "sparkle-tools.log", timeout=180)
    tools = logged([sys.executable, '-m', 'unittest', 'discover', '-s', 'Tests/BuildTools', '-v'],
                   'tools-tests.log', timeout=120).read_text()
    count = re.search(r'^Ran (\d+) tests? in ', tools, re.M)
    if not count or int(count[1]) == 0 or re.search(r'\bskipped\b', tools):
        raise RuntimeError('Build-/Netzwerk-Regressionsprüfungen fehlen oder wurden übersprungen.')
    logged([sys.executable, 'Scripts/check-migration-sql.py'], 'migration.json', timeout=60)
    manifest = json.loads((ROOT / 'Models/manifest.json').read_text())
    model = Path(os.environ.get('LOCALSEEK_TEST_MODEL') or os.environ.get('LOCALSEEK_MODEL') or
                 str(Path.home() / 'Library/Application Support/LocalSeek/models' / manifest['name'])).expanduser()
    digest = hashlib.sha256()
    with model.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != manifest['sha256']:
        raise RuntimeError('Das gepinnte Modell fehlt für die echten Embedding-Integrationstests.')
    bundle = REPORTS / ('release-tests-' + uuid.uuid4().hex + '.xcresult')
    environment = os.environ | {'LOCALSEEK_TEST_MODEL': str(model), 'LOCALSEEK_TEST_RESULT_BUNDLE': str(bundle)}
    logged(['bash', 'Scripts/test.sh'], 'tests.log', environment=environment)
    summary = json.loads(output('xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)))
    (REPORTS / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    passed = passed_swift_tests(summary)
    if before != inputs():
        raise RuntimeError('Quellstand/System hat sich während der Tests geändert; erneut testen.')
    receipt = dict(inputs=before, completedAt=time.time(), passedTests=passed,
                   failedTests=0, skippedTests=0, toolTests=int(count[1]), resultBundle=str(bundle))
    pending = RECEIPT.with_suffix('.pending')
    pending.write_text(json.dumps(receipt, indent=2) + '\n')
    pending.replace(RECEIPT)
    print(f"Release-Tests bestanden: {receipt['passedTests']} Swift-Tests, {receipt['toolTests']} Build-Tests; keine Skips.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='Aktuelles erfolgreiches Testergebnis prüfen')
    args = parser.parse_args()
    try:
        if args.verify:
            verify()
            print('Unit-/Integrationstests für diesen Quellstand sind bestanden und aktuell.')
        else:
            run_tests()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print('Release-Testfreigabe fehlt: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
