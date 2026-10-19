#!/usr/bin/env python3
"""Keep one successful DMG per branch and the five newest diagnostic artifacts."""
import json
import os
import re
import subprocess

repository = os.environ['GITHUB_REPOSITORY']
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
    raise SystemExit('Invalid repository')
raw = subprocess.check_output([
    'gh', 'api', '--paginate', f'repos/{repository}/actions/artifacts?per_page=100',
    '--jq', '.artifacts[] | {id,name,created_at,expired}',
], text=True)
# Compact each JSON object into one line; gh's --jq prints objects over several lines.
decoder = json.JSONDecoder()
entries = []
while raw.strip():
    raw = raw.lstrip()
    entry, end = decoder.raw_decode(raw)
    entries.append(entry)
    raw = raw[end:]
groups = {}
for entry in entries:
    name = entry['name']
    match = re.fullmatch(r'LocalSeek-(main|dev)-\d+-\d+', name)
    diagnostics = re.fullmatch(r'LocalSeek-diagnostics-(main|dev)-\d+-\d+', name)
    if match or diagnostics:
        group = 'diagnostics' if diagnostics else match[1]
        groups.setdefault(group, []).append(entry)
removed = 0
for group, artifacts in groups.items():
    artifacts.sort(key=lambda item: (item['created_at'], item['id']), reverse=True)
    keep = 5 if group == 'diagnostics' else 1
    active = 0
    for artifact in artifacts:
        if not artifact['expired']:
            active += 1
        if artifact['expired'] or active > keep:
            subprocess.run(['gh', 'api', '--method', 'DELETE',
                            f"repos/{repository}/actions/artifacts/{int(artifact['id'])}"], check=True)
            removed += 1
print(f'Removed {removed} superseded LocalSeek artifacts')
