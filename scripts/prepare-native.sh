#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/.build/whisper-source"
BUILD_DIR="$PROJECT_DIR/.build/whisper-native"
REVISION="927cfce34f31707e17f2bff35c349632fb9e2c3a"
mkdir -p "$PROJECT_DIR/.build"
if [ ! -d "$SOURCE_DIR/.git" ]; then
    git clone --depth 1 --branch v1.9.4 https://github.com/ggml-org/whisper.cpp.git "$SOURCE_DIR"
fi
if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$REVISION" ]; then
    echo "Uventet whisper.cpp-versjon i $SOURCE_DIR" >&2
    exit 1
fi
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$BUILD_DIR" --target whisper -j 4
