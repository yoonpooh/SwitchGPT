#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-run}"
case "$MODE" in run|--verify|--build|--release) ;; *) echo 'usage: build_and_run.sh [run|--verify|--build|--release]'; exit 2;; esac
CONFIGURATION=debug
if [ "$MODE" = '--release' ]; then CONFIGURATION=release; fi
if [ "$MODE" = run ]; then pkill -x SwitchGPT || true; fi
swift build -c "$CONFIGURATION"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP='dist/SwitchGPT.app'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# Build the pinned dependency for our deployment target; Homebrew bottles may
# require a newer macOS than the application supports.
ZSTD_VERSION=1.5.7
ZSTD_SHA256=37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
ZSTD_CACHE="$PWD/.build/zstd-macos14"
ZSTD_ARCHIVE="$ZSTD_CACHE/zstd-$ZSTD_VERSION.tar.gz"
ZSTD_PREFIX="$ZSTD_CACHE/zstd-$ZSTD_VERSION"
mkdir -p "$ZSTD_CACHE"
if [ ! -f "$ZSTD_ARCHIVE" ]; then
    curl --fail --location --silent --show-error \
        "https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VERSION.tar.gz" \
        -o "$ZSTD_ARCHIVE.download"
    mv "$ZSTD_ARCHIVE.download" "$ZSTD_ARCHIVE"
fi
printf '%s  %s\n' "$ZSTD_SHA256" "$ZSTD_ARCHIVE" | shasum -a 256 -c -
if [ ! -d "$ZSTD_PREFIX" ]; then tar -xzf "$ZSTD_ARCHIVE" -C "$ZSTD_CACHE"; fi
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" MACOSX_DEPLOYMENT_TARGET=14.0 make -C "$ZSTD_PREFIX/lib" -j "$(sysctl -n hw.ncpu)" \
    libzstd CC="$(xcrun -f clang)" CFLAGS="-O3 -mmacosx-version-min=14.0" \
    LDFLAGS="-dynamiclib -pthread -mmacosx-version-min=14.0"
if [ -f "$APP/Contents/Frameworks/libzstd.dylib" ]; then chmod u+w "$APP/Contents/Frameworks/libzstd.dylib"; fi
cp "$ZSTD_PREFIX/lib/libzstd.dylib" "$APP/Contents/Frameworks/libzstd.dylib"
chmod u+w "$APP/Contents/Frameworks/libzstd.dylib"
install_name_tool -id @rpath/libzstd.dylib "$APP/Contents/Frameworks/libzstd.dylib"
cp "$ZSTD_PREFIX/LICENSE" "$APP/Contents/Resources/zstd-LICENSE"
codesign --force --sign - "$APP/Contents/Frameworks/libzstd.dylib"
cp Assets/SwitchGPTMenu@2x.png "$APP/Contents/Resources/"
cp Assets/SwitchGPT.icns "$APP/Contents/Resources/"
cp -R "$BUILD_DIR/SwitchGPT_SwitchGPT.bundle" "$APP/Contents/Resources/"
cp "$BUILD_DIR/SwitchGPT" "$APP/Contents/MacOS/SwitchGPT"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SwitchGPT</string>
<key>CFBundleIdentifier</key><string>local.codex-account-switch</string>
<key>CFBundleName</key><string>SwitchGPT</string>
<key>CFBundleDisplayName</key><string>SwitchGPT</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>zh-Hans</string><string>ja</string></array>
<key>CFBundleIconFile</key><string>SwitchGPT.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.5</string>
<key>CFBundleVersion</key><string>25</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
if [ "$MODE" = run ]; then open -n "$APP"; fi
if [ "$MODE" = '--verify' ]; then
    if pgrep -x SwitchGPT >/dev/null; then
        echo 'SwitchGPT is already running; verified the build and signature without launching a competing relay.'
    else
        open -n "$APP"
        sleep 2
        VERIFY_EXECUTABLE="$PWD/$APP/Contents/MacOS/SwitchGPT"
        VERIFY_PID="$(pgrep -f "^$VERIFY_EXECUTABLE$")"
        test -n "$VERIFY_PID"
        kill "$VERIFY_PID"
    fi
fi
