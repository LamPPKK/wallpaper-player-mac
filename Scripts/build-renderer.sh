#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/ExternalRenderers/wallpaperengine-mac-renderer"
BUILD="$SOURCE/build"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
DEPENDENCY_LOCK="${RENDERER_DEPENDENCY_LOCK:-$BUILD/dependencies.lock.tsv}"

if [ ! -f "$SOURCE/CMakeLists.txt" ]; then
  printf '%s\n' "Renderer source is missing from $SOURCE" >&2
  exit 1
fi

cmake -S "$SOURCE" -B "$BUILD-arm64" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DWPENGINE_SCENE_ONLY=ON -DBUILD_TESTING=OFF
cmake --build "$BUILD-arm64" --config Release --parallel
cmake -S "$SOURCE" -B "$BUILD-x86_64" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DWPENGINE_SCENE_ONLY=ON -DBUILD_TESTING=OFF
cmake --build "$BUILD-x86_64" --config Release --parallel

ARM_BINARY="${ARM_RENDERER_BINARY:-$BUILD-arm64/output/wwb-scene-renderer}"
INTEL_BINARY="${INTEL_RENDERER_BINARY:-$BUILD-x86_64/output/wwb-scene-renderer}"
"$ROOT/Scripts/bundle-renderer-runtime.sh" \
  "$ARM_BINARY" "$BUILD-arm64/runtime" arm64 "$DEPENDENCY_LOCK"
"$ROOT/Scripts/bundle-renderer-runtime.sh" \
  "$INTEL_BINARY" "$BUILD-x86_64/runtime" x86_64 "$DEPENDENCY_LOCK"
"$ROOT/Scripts/merge-renderer-runtime.sh" "$BUILD-arm64/runtime" "$BUILD-x86_64/runtime" "$BUILD/runtime"
