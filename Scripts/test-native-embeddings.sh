#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/NativeTests
xcrun clang++ -std=c++17 -O2 -g -I LlamaBridge/include -I build/Native/include \
  LlamaBridge/src/localseek_llama.cpp Tests/Native/EmbeddingBatchHarness.cpp \
  -L build/Native/lib -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas \
  -framework Accelerate -framework Metal -framework Foundation -o build/NativeTests/embedding-batch-harness
build/NativeTests/embedding-batch-harness "${LOCALSEEK_MODEL:-$HOME/Library/Application Support/LocalSeek/models/multilingual-e5-small-q8_0.gguf}"
