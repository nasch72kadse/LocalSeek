#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:?Aufruf: bash Scripts/verify-artifact.sh /Pfad/LocalSeek.dmg}"
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
[[ "$(readlink "$MOUNT/Programme")" == '/Applications' ]]
[[ -f "$MOUNT/Installieren.txt" ]]
Scripts/verify-bundle.sh "$MOUNT/LocalSeek.app"
printf 'DMG geprüft: App, Modell, Helper, Bibliotheken und Programme-Verknüpfung enthalten.\n'
