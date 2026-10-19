#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/NativeTests
xcrun clang++ -std=c++17 -O2 -g -I LlamaBridge/include \
  LlamaBridge/src/localseek_ann.cpp Tests/Native/ANNHarness.cpp -o build/NativeTests/ann-harness
build/NativeTests/ann-harness "${1:-10000}"
