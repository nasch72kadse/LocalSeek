"""Signed Sparkle appcast, published atomically on an independent updates branch."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

PUBLIC_KEY = 'II/z8P97v8IcdT32JGpeegrOtF2BrNVtZKKpXVOmv2c='
ACCOUNT = 'com.localseek.updates'
REPOSITORY = 'nasch72kadse/LocalSeek'
FEED_URL = f'https://raw.githubusercontent.com/{REPOSITORY}/updates/appcast.xml'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
BOT = dict(name='LocalSeek releases', email='40856036+nasch72kadse@users.noreply.github.com')


def tool(root, name):
    return str(root / 'build/Dependencies/Sparkle/bin' / name)


def api(run, repository, suffix, payload=None):
    args = ['gh', 'api', '--hostname', 'github.com', f'repos/{repository}/{suffix}']
    if payload is not None:
        # Structured JSON goes through a file; no shell interpolation of feed content.
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as request:
            json.dump(payload, request)
            request.flush()
            return json.loads(run(*args, '--method', 'POST', '--input', request.name))
    return json.loads(run(*args))


def parse_feed(content):
    try:
        root = ET.fromstring(content)
        if root.tag != 'rss' or root.find('channel') is None:
            raise ValueError('Missing RSS channel')
        for item in root.findall('channel/item'):
            version = item.findtext(f'{{{NS}}}version', '')
            if not re.fullmatch(r'[1-9][0-9]*', version):
                raise ValueError('Feed build numbers must be positive integers')
        return root
    except (ET.ParseError, ValueError) as error:
        raise RuntimeError(f'Invalid existing update feed: {error}') from error


def preflight(root, run, repository, build_number):
    if repository != REPOSITORY:
        raise RuntimeError('The app feed is configured for nasch72kadse/LocalSeek; repository mismatch.')
    run('bash', 'Scripts/sparkle-tools.sh')
    if run(tool(root, 'generate_keys'), '--account', ACCOUNT, '-p') != PUBLIC_KEY:
        raise RuntimeError('Sparkle signing key is missing or does not match the embedded public key.')
    refs = api(run, repository, 'git/matching-refs/heads/updates')
    refs = [ref for ref in refs if ref['ref'] == 'refs/heads/updates']
    if not refs:
        return dict(parent=None, content=None)
    parent = refs[0]['object']['sha']
    commit = api(run, repository, f'git/commits/{parent}')
    tree = api(run, repository, 'git/trees/' + commit['tree']['sha'])
    blobs = [entry for entry in tree['tree'] if entry['path'] == 'appcast.xml' and entry['type'] == 'blob']
    if len(blobs) != 1:
        raise RuntimeError('Existing updates branch has no unique appcast.xml; refusing to replace it.')
    blob = api(run, repository, 'git/blobs/' + blobs[0]['sha'])
    content = base64.b64decode(blob['content'], validate=False)
    # Validate authenticity before carrying existing stable or preview items forward.
    import tempfile
    with tempfile.TemporaryDirectory(dir=root / 'build') as temporary:
        path = Path(temporary) / 'appcast.xml'
        path.write_bytes(content)
        run(tool(root, 'sign_update'), '--account', ACCOUNT, '--verify', str(path))
    feed = parse_feed(content)
    highest = max((int(item.findtext(f'{{{NS}}}version')) for item in feed.findall('channel/item')), default=0)
    if build_number <= highest:
        raise RuntimeError(f'CURRENT_PROJECT_VERSION must exceed published build {highest}.')
    return dict(parent=parent, content=content.decode('utf-8'))


def prepare(root, run, plan, dmg, output):
    info = dmg.parent / 'LocalSeek.app/Contents/Info.plist'
    import plistlib
    with info.open('rb') as source:
        settings = plistlib.load(source)
    expected = dict(SUFeedURL=FEED_URL, SUPublicEDKey=PUBLIC_KEY,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    CFBundleVersion=str(plan['build_number']),
                    LocalSeekUpdateChannel='dev' if plan['branch'] == 'dev' else 'stable')
    if any(settings.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Packaged updater configuration does not match this release.')
    signature = run(tool(root, 'sign_update'), '--account', ACCOUNT, '-p', str(dmg))
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise RuntimeError('Invalid Sparkle archive signature.')
    run(tool(root, 'sign_update'), '--account', ACCOUNT, '--verify', str(dmg), signature)
    snapshot = plan['feed']
    if snapshot['content']:
        feed = parse_feed(snapshot['content'])
    else:
        feed = ET.Element('rss', version='2.0')
        channel = ET.SubElement(feed, 'channel')
        ET.SubElement(channel, 'title').text = 'LocalSeek updates'
        ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    channel = feed.find('channel')
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f"LocalSeek {plan['version']}"
    ET.SubElement(item, f'{{{NS}}}version').text = str(plan['build_number'])
    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = plan['version']
    if plan['branch'] == 'dev':
        ET.SubElement(item, f'{{{NS}}}channel').text = 'dev'
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, f'{{{NS}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, 'link').text = f"https://github.com/{REPOSITORY}/releases/tag/{plan['tag']}"
    ET.SubElement(item, 'description').text = (
        'Signed and notarized LocalSeek update. Includes the local search model and OCR helper.')
    ET.SubElement(item, 'enclosure', {
        'url': f"https://github.com/{REPOSITORY}/releases/download/{plan['tag']}/{dmg.name}",
        f'{{{NS}}}edSignature': signature, 'length': str(dmg.stat().st_size),
        'type': 'application/octet-stream'})
    channel.insert(0, item)
    # Keep recent versions of both channels, never drop stable items for a preview.
    counts = {}
    for entry in list(channel.findall('item')):
        name = entry.findtext(f'{{{NS}}}channel', 'stable')
        counts[name] = counts.get(name, 0) + 1
        if counts[name] > 3:
            channel.remove(entry)
    output.write_bytes(ET.tostring(feed, encoding='utf-8', xml_declaration=True))
    run(tool(root, 'sign_update'), '--account', ACCOUNT, str(output))
    run(tool(root, 'sign_update'), '--account', ACCOUNT, '--verify', str(output))
    return output


def publish(run, plan, path):
    # Caller publishes and checks the immutable release assets first. The branch
    # update is a compare-and-swap: concurrent publishers cannot lose feed items.
    repository = plan['repository']
    blob = api(run, repository, 'git/blobs', dict(
        content=base64.b64encode(path.read_bytes()).decode('ascii'), encoding='base64'))
    tree = api(run, repository, 'git/trees', dict(tree=[dict(
        path='appcast.xml', mode='100644', type='blob', sha=blob['sha'])]))
    parent = plan['feed']['parent']
    commit = api(run, repository, 'git/commits', dict(
        message=f"Publish signed update feed for {plan['tag']}", tree=tree['sha'],
        parents=[parent] if parent else [], author=BOT, committer=BOT))
    if parent:
        # A non-fast-forward update is rejected if the feed changed meanwhile.
        args = ['gh', 'api', '--hostname', 'github.com', '--method', 'PATCH',
                f'repos/{repository}/git/refs/heads/updates', '-f', 'sha=' + commit['sha'], '-F', 'force=false']
        run(*args)
    else:
        api(run, repository, 'git/refs', dict(ref='refs/heads/updates', sha=commit['sha']))
