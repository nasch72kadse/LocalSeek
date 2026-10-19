#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PIN=d81235049384534c167caea52b85a694f6103d14
SOURCE=build/Dependencies/llama.cpp
command -v cmake >/dev/null || { echo 'CMake fehlt: brew install cmake' >&2; exit 1; }
if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p build/Dependencies
  git clone --depth 1 --branch v0.6.0 https://github.com/ggml-org/llama.cpp.git "$SOURCE"
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { echo 'Unerwartete llama.cpp-Revision' >&2; exit 1; }
cmake -S "$SOURCE" -B build/NativeBuild \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$ROOT/build/Native" -DBUILD_SHARED_LIBS=OFF \
  -DGGML_BACKEND_DL=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_MACOSX_VERSION_MIN=14.0 \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_CCACHE=OFF \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF
cmake --build build/NativeBuild --parallel 4
cmake --install build/NativeBuild
