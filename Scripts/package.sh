#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  '') exec Scripts/build.sh ;;
  --skip-build) ;;
  *) echo 'Aufruf: Scripts/package.sh [--skip-build]' >&2; exit 1 ;;
esac
# Refuse to package an older binary after code or dependency changes.
[[ -f build/source-checksums.txt && -f build/last-built-configuration.txt ]] || { echo 'Bitte zuerst Scripts/build.sh ausführen.' >&2; exit 1; }
[[ "$(cat build/last-built-configuration.txt)" == 'Release' ]] || { echo 'Paketbau benötigt einen Release-Build.' >&2; exit 1; }
CHECKS="$(mktemp build/package-sources.XXXXXX)"
trap 'rm -f "$CHECKS"' EXIT
bash Scripts/source-checksums.sh > "$CHECKS"
cmp -s build/source-checksums.txt "$CHECKS" || { echo 'Quellstand geändert. Bitte Scripts/build.sh erneut ausführen.' >&2; exit 1; }
MODEL="${LOCALSEEK_MODEL:-$HOME/Library/Application Support/LocalSeek/models/multilingual-e5-small-q8_0.gguf}"
EXPECTED=e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93
[[ -f "$MODEL" ]] || { echo 'Modell fehlt. LOCALSEEK_MODEL auf die lokale GGUF-Datei setzen.' >&2; exit 1; }
[[ "$(shasum -a 256 "$MODEL" | cut -d ' ' -f 1)" == "$EXPECTED" ]] || { echo 'Modell-Prüfsumme stimmt nicht.' >&2; exit 1; }
SIGNING_ID="${LOCALSEEK_SIGN_IDENTITY:--}"
NOTARY_ARGS=(--keychain-profile "${LOCALSEEK_NOTARY_PROFILE:-}")
if [[ -n "${LOCALSEEK_NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_ARGS+=(--keychain "$LOCALSEEK_NOTARY_KEYCHAIN")
fi
if [[ -n "${LOCALSEEK_NOTARY_PROFILE:-}" && "$SIGNING_ID" == '-' ]]; then
  echo 'Notarisierung benötigt LOCALSEEK_SIGN_IDENTITY mit einer Developer-ID-Signatur.' >&2
  exit 1
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw build/DerivedData/Build/Products/Release/LocalSeek.app/Contents/Info.plist)"
mkdir -p build/packages
DEST="$(mktemp -d "build/packages/LocalSeek-${VERSION}-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
APP="$DEST/LocalSeek.app"
ditto build/DerivedData/Build/Products/Release/LocalSeek.app "$APP"
mkdir -p "$APP/Contents/Resources/Models" "$APP/Contents/Resources/ThirdParty"
cp "$MODEL" "$APP/Contents/Resources/Models/"
cp Models/manifest.json "$APP/Contents/Resources/Models/manifest.json"
cp Licenses/* THIRD_PARTY_NOTICES.md Package.resolved Models/native-dependencies.json "$APP/Contents/Resources/ThirdParty/"
cp README.md "$APP/Contents/Resources/README.md"
cp HANDOFF/INSTALLATION.md "$APP/Contents/Resources/INSTALLATION.md"
if [[ -f build/source-checksums.txt ]]; then cp build/source-checksums.txt "$APP/Contents/Resources/source-checksums.txt"; fi
SIGN_ARGS=(--force --sign "$SIGNING_ID")
if [[ "$SIGNING_ID" == '-' ]]; then
  SIGN_ARGS+=(--options 0 --timestamp=none)
else
  SIGN_ARGS+=(--options runtime --timestamp)
fi
for framework in "$APP"/Contents/Frameworks/*.framework; do
  [[ ! -d "$framework" ]] || codesign "${SIGN_ARGS[@]}" "$framework"
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/LocalSeekOCR"
codesign "${SIGN_ARGS[@]}" "$APP"
Scripts/verify-bundle.sh "$APP"
ditto -c -k --keepParent "$APP" "$DEST/LocalSeek.zip"
if [[ -n "${LOCALSEEK_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DEST/LocalSeek.zip" "${NOTARY_ARGS[@]}" --wait --timeout 10m
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  ditto -c -k --keepParent "$APP" "$DEST/LocalSeek-notarized.zip"
fi

# Finder installation: no Terminal, package manager, model download or installer scripts.
STAGING="$DEST/DiskImage"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/LocalSeek.app"
ln -s /Applications "$STAGING/Programme"
cat > "$STAGING/Installieren.txt" <<'INSTALL'
LocalSeek installieren

1. LocalSeek.app auf den Ordner „Programme“ ziehen.
2. Das Laufwerk „LocalSeek“ im Finder auswerfen.
3. LocalSeek aus „Programme“ starten und die gewünschten Suchordner auswählen.

Enthalten: Suchmodell, OCR-Hilfsprozess, native Bibliotheken und Metal.
Keine zusätzlichen Downloads oder Terminal-Befehle erforderlich.
Voraussetzung: Apple Silicon (M1 oder neuer), macOS 14 oder neuer.

Ein privat signierter, nicht notarisierter Build kann von macOS beim Start
blockiert werden. Die Freigabe hängt von der konkreten macOS-Meldung und den
Sicherheitsvorgaben dieses Macs ab. Die App verändert keine Sicherheitsregeln.
INSTALL
DMG="$DEST/LocalSeek-${VERSION}-arm64.dmg"
hdiutil create -quiet -volname LocalSeek -srcfolder "$STAGING" -format UDZO "$DMG"
if [[ "$SIGNING_ID" != '-' ]]; then
  codesign --force --sign "$SIGNING_ID" --timestamp "$DMG"
fi
if [[ -n "${LOCALSEEK_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --timeout 10m
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
bash Scripts/verify-artifact.sh "$DMG"

# Publish only after all checks succeed. Keep the previous timestamped releases.
cp "$DMG" build/LocalSeek.dmg.pending
mv -f build/LocalSeek.dmg.pending build/LocalSeek.dmg
shasum -a 256 build/LocalSeek.dmg > build/LocalSeek.dmg.sha256
printf '%s\n' "$PWD/$APP" > build/latest-package.txt
printf '%s\n' "$PWD/$DMG" > build/latest-artifact.txt
printf 'Fertige Datei für den neuen Mac: %s/build/LocalSeek.dmg\n' "$PWD"
printf 'Archivierte Version: %s/%s\n' "$PWD" "$DMG"
if [[ -z "${LOCALSEEK_NOTARY_PROFILE:-}" ]]; then
  printf 'Startfreigabe: nicht notariert; macOS kann den ersten Start blockieren.\n'
fi
