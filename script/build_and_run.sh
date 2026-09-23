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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
<key>CFBundleShortVersionString</key><string>0.2.7</string>
<key>CFBundleVersion</key><string>27</string>
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
