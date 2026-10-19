#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild test -scheme LocalSeek -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=-
