#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BUILD_DIR="$SCRIPT_DIR/.icon-build"
ASSETS_DIR="$SCRIPT_DIR/Assets"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

mkdir -p "$BUILD_DIR/modules" "$ICONSET_DIR"

CLANG_MODULE_CACHE_PATH="$BUILD_DIR/modules" \
    swiftc "$SCRIPT_DIR/Tools/IconProcessor.swift" \
    -o "$BUILD_DIR/IconProcessor"

"$BUILD_DIR/IconProcessor" \
    "$ASSETS_DIR/AppIconSource.png" \
    "$ASSETS_DIR/MenuBarIconSource.png" \
    "$ASSETS_DIR"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size="${specification%% *}"
    filename="${specification#* }"
    sips -z "$size" "$size" "$ASSETS_DIR/AppIcon.png" \
        --out "$ICONSET_DIR/$filename" >/dev/null
done

"$BUILD_DIR/IconProcessor" --icns "$ICONSET_DIR" "$ASSETS_DIR/AppIcon.icns"

echo "Iconos generados en: $ASSETS_DIR"
