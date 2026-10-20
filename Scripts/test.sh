#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/local-build-config.sh
# xcodebuild forwards TEST_RUNNER_* to the test process without that prefix.
if [[ -n "${LOCALSEEK_TEST_MODEL:-${LOCALSEEK_MODEL:-}}" ]]; then
  export TEST_RUNNER_LOCALSEEK_TEST_MODEL="${LOCALSEEK_TEST_MODEL:-$LOCALSEEK_MODEL}"
fi
TEST_ARGS=("CODE_SIGN_IDENTITY=${LOCALSEEK_TEST_SIGN_IDENTITY:--}")
if [[ -n "${LOCALSEEK_TEST_RESULT_BUNDLE:-}" ]]; then
  TEST_ARGS+=(-resultBundlePath "$LOCALSEEK_TEST_RESULT_BUNDLE")
fi
if [[ -n "${LOCALSEEK_TEST_SIGN_IDENTITY:-}" ]]; then
  TEST_ARGS+=(CODE_SIGN_STYLE=Manual)
fi
xcodebuild test -scheme LocalSeek -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${LOCALSEEK_TEST_DERIVED_DATA:-build/DerivedData}" -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 120 \
  "${TEST_ARGS[@]}"
