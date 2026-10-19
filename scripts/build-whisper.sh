#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE="$ROOT/build/Whisper"
SOURCE="$CACHE/whisper.cpp-1.9.5"
ARCHIVE="$CACHE/source.tar.gz"
mkdir -p "$CACHE"
if [ ! -d "$SOURCE" ]; then
  curl --fail --location --retry 2 --output "$ARCHIVE" \
    https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz
  printf '%s  %s\n' ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720 "$ARCHIVE" | shasum -a 256 -c -
  tar -xzf "$ARCHIVE" -C "$CACHE"
fi
cmake -S "$SOURCE" -B "$CACHE/compiled" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$ROOT=/_/pflow" \
  -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$ROOT=/_/pflow" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
cmake --build "$CACHE/compiled" --config Release --target whisper-cli -j 4
DESTINATION="${TARGET_BUILD_DIR:-$ROOT/build}/${CONTENTS_FOLDER_PATH:-Whisper.app/Contents}/Helpers"
mkdir -p "$DESTINATION"
cp "$CACHE/compiled/bin/whisper-cli" "$DESTINATION/whisper-cli"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DESTINATION/whisper-cli"
fi
