#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-native.sh
command -v xcodegen >/dev/null || { echo 'XcodeGen fehlt: brew install xcodegen' >&2; exit 1; }
xcodegen generate
mkdir -p LocalSeek.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved LocalSeek.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild build -scheme LocalSeek -configuration "${CONFIGURATION:-Release}" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=-

# Source provenance, including untracked project files; no document/source-folder data.
bash Scripts/source-checksums.sh > build/source-checksums.txt.pending
mv build/source-checksums.txt.pending build/source-checksums.txt
printf '%s\n' "${CONFIGURATION:-Release}" > build/last-built-configuration.txt

# A successful Release build always ends with the transferable, verified DMG.
if [[ "${CONFIGURATION:-Release}" == 'Release' ]]; then
  Scripts/package.sh --skip-build
else
  printf 'Debug-Build fertig. Für die übertragbare DMG einen Release-Build ausführen.\n'
fi
