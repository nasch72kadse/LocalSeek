#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# xcodebuild forwards TEST_RUNNER_* to the test process without that prefix.
if [[ -n "${LOCALSEEK_TEST_MODEL:-${LOCALSEEK_MODEL:-}}" ]]; then
  export TEST_RUNNER_LOCALSEEK_TEST_MODEL="${LOCALSEEK_TEST_MODEL:-$LOCALSEEK_MODEL}"
fi
xcodebuild test -scheme LocalSeek -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO CODE_SIGN_IDENTITY=-
