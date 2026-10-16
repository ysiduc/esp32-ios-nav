#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA_INPUT="${1:-$HOME/Downloads/WazePlus_4.100.0.ipa}"
OUTPUT_DIR_ARG="${2:-$DIR/output}"
mkdir -p "$OUTPUT_DIR_ARG"
OUTPUT_DIR="$(cd "$OUTPUT_DIR_ARG" && pwd)"
OUTPUT_IPA="$OUTPUT_DIR/Waze-ESP32-HUD-PRODUCTION.ipa"
WORK_DIR=$(mktemp -d /tmp/waze_build_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "📦 1. Checking / Compiling WazeESP32Nav.dylib..."

if [ -f "$OUTPUT_DIR/WazeESP32Nav.dylib" ]; then
    echo "✅ Found precompiled dylib at $OUTPUT_DIR/WazeESP32Nav.dylib"
    cp "$OUTPUT_DIR/WazeESP32Nav.dylib" "$WORK_DIR/WazeESP32Nav.dylib"
elif [ -f "$DIR/output/WazeESP32Nav.dylib" ]; then
    echo "✅ Found precompiled dylib at $DIR/output/WazeESP32Nav.dylib"
    cp "$DIR/output/WazeESP32Nav.dylib" "$WORK_DIR/WazeESP32Nav.dylib"
else
    # Detect Clang / SDK
    SDK_PATH=""
    if command -v xcrun &>/dev/null; then
        SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
    fi

    CLANG_FLAGS=(
        -target arm64-apple-ios14.0
        -dynamiclib
        -fobjc-arc
        -O2
        -Wall
        -framework Foundation
        -framework UIKit
        -framework CoreBluetooth
        -framework CoreGraphics
        -framework QuartzCore
        -install_name "@rpath/WazeESP32Nav.dylib"
        -o "$WORK_DIR/WazeESP32Nav.dylib"
        "$DIR/ESP32BLEManager.m"
        "$DIR/ESP32VirtualHUDView.m"
        "$DIR/WazeMapStreamServer.m"
        "$DIR/WazeESP32Tweak.m"
    )

    if [ -n "$SDK_PATH" ]; then
        CLANG_FLAGS+=(-isysroot "$SDK_PATH")
    fi

    echo "⚙️ Compiling with clang..."
    clang "${CLANG_FLAGS[@]}"
    echo "✅ Compiled WazeESP32Nav.dylib successfully!"
    cp "$WORK_DIR/WazeESP32Nav.dylib" "$OUTPUT_DIR/WazeESP32Nav.dylib"
fi

if [ ! -f "$IPA_INPUT" ]; then
    echo "⚠️ Warning: Input IPA not found at $IPA_INPUT."
    echo "Compiled dylib saved at: $OUTPUT_DIR/WazeESP32Nav.dylib"
    exit 0
fi

echo "📦 2. Extracting Waze IPA: $IPA_INPUT..."
unzip -q "$IPA_INPUT" -d "$WORK_DIR/extracted"

APP_PATH=$(find "$WORK_DIR/extracted/Payload" -name "Waze.app" -type d | head -n 1)
if [ -z "$APP_PATH" ]; then
    echo "❌ Error: Waze.app not found in IPA!"
    exit 1
fi

echo "💉 3. Injecting dylib into Mach-O executable..."
mkdir -p "$APP_PATH/Frameworks"
cp "$WORK_DIR/WazeESP32Nav.dylib" "$APP_PATH/Frameworks/"

python3 "$DIR/inject_dylib.py" "$APP_PATH/Waze" "@rpath/WazeESP32Nav.dylib"

echo "📦 4. Repackaging into $OUTPUT_IPA..."
cd "$WORK_DIR/extracted"
zip -q -r -y "$OUTPUT_IPA" Payload/

echo "=================================================="
echo "🎉 SUCCESS! Output IPA created at:"
echo "   $OUTPUT_IPA"
echo "   Size: $(du -sh "$OUTPUT_IPA" | cut -f1)"
echo "=================================================="
