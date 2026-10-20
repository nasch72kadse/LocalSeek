#!/bin/bash
set -euo pipefail
APP="$1"
# Inspect actual resources and binaries, before a package can reach Apple/GitHub.
python3 "$(dirname "$0")/check-bundle-privacy.py" "$APP"
codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/LocalSeek" "$APP/Contents/Helpers/LocalSeekOCR" "$APP/Contents/Frameworks/SharedCore.framework/Versions/A/SharedCore"; do
  [[ -f "$binary" ]] || { echo "Binärdatei fehlt: $binary" >&2; exit 1; }
  DEPENDENCIES="$(otool -L "$binary")"
  printf '%s\n' "$DEPENDENCIES" | awk 'NR > 1 {print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/*)
        [[ "$dependency" != *'/../'* && -f "$APP/Contents/Frameworks/${dependency#@rpath/}" ]] || {
          echo "Nicht enthaltene Laufzeitabhängigkeit: $dependency" >&2; exit 1;
        } ;;
      *) echo "Externe Laufzeitabhängigkeit: $dependency" >&2; exit 1 ;;
    esac
  done
  [[ "$(lipo -archs "$binary")" == 'arm64' ]] || { echo 'Unerwartete Architektur' >&2; exit 1; }
  xcrun vtool -show-build "$binary"
done
MANIFEST="$APP/Contents/Resources/Models/manifest.json"
MODEL_NAME="$(plutil -extract name raw "$MANIFEST")"
EXPECTED="$(plutil -extract sha256 raw "$MANIFEST")"
[[ "$MODEL_NAME" != */* && "$MODEL_NAME" == *.gguf && "$EXPECTED" =~ ^[0-9a-f]{64}$ ]]
MODEL="$APP/Contents/Resources/Models/$MODEL_NAME"
[[ -f "$MODEL" && "$(shasum -a 256 "$MODEL" | awk '{print $1}')" == "$EXPECTED" ]] || {
  echo 'Das gebündelte Suchmodell fehlt oder seine Prüfsumme ist falsch.' >&2; exit 1;
}
