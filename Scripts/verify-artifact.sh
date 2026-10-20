#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:?Usage: bash Scripts/verify-artifact.sh /path/to/LocalSeek.dmg}"
hdiutil verify -quiet "$DMG"
MOUNT="$(mktemp -d "$PWD/build/verify-dmg.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach -quiet "$MOUNT" || return; fi
  rmdir "$MOUNT"
}
trap cleanup EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
MOUNTED=1
[[ "$(readlink "$MOUNT/Applications")" == '/Applications' ]]
[[ -f "$MOUNT/Install.txt" ]]
Scripts/verify-bundle.sh "$MOUNT/LocalSeek.app"
printf 'DMG verified: app, model, OCR helper, libraries, and Applications shortcut included.\n'
