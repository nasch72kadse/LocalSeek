#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/local-build-config.sh
if [[ "${CONFIGURATION:-Release}" == Release && "$LOCALSEEK_PUBLISH_RELEASE" == 1 ]]; then
  bash Scripts/publish-release.sh --check
  export LOCALSEEK_BUILT_COMMIT="$(git rev-parse HEAD)"
fi
Scripts/build-native.sh
command -v xcodegen >/dev/null || { echo 'XcodeGen fehlt: brew install xcodegen' >&2; exit 1; }
xcodegen generate
mkdir -p LocalSeek.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved LocalSeek.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [[ "${CONFIGURATION:-Release}" == Release ]]; then
  # CI may already have run this gate earlier in the same job. Local builds
  # always run fresh tests, before signing/notary uploads or creating a DMG.
  if [[ "${GITHUB_ACTIONS:-}" != true ]] || ! bash Scripts/test-release.sh --verify; then
    bash Scripts/test-release.sh
  fi
fi
UPDATE_CHANNEL=stable
if [[ "$(git branch --show-current)" == dev ]]; then UPDATE_CHANNEL=dev; fi
xcodebuild build -scheme LocalSeek -configuration "${CONFIGURATION:-Release}" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- "LOCALSEEK_UPDATE_CHANNEL=$UPDATE_CHANNEL"

# Source provenance, including untracked project files; no document/source-folder data.
bash Scripts/source-checksums.sh > build/source-checksums.txt.pending
mv build/source-checksums.txt.pending build/source-checksums.txt
printf '%s\n' "${CONFIGURATION:-Release}" > build/last-built-configuration.txt

# A successful Release build always ends with the transferable, verified DMG.
if [[ "${CONFIGURATION:-Release}" == 'Release' ]]; then
  Scripts/package.sh --skip-build
  if [[ "$LOCALSEEK_PUBLISH_RELEASE" == 1 ]]; then
    bash Scripts/publish-release.sh --publish
  fi
else
  printf 'Debug-Build fertig. Für die übertragbare DMG einen Release-Build ausführen.\n'
  python3 Scripts/build_retention.py --apply || printf 'Build cleanup could not finish.\n' >&2
fi
