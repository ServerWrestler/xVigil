#!/bin/sh
# Builds a distributable xVigil.app into dist/ and zips it.
#
#   scripts/make-app.sh [version]     e.g. scripts/make-app.sh 0.1.0
#
# The bundle is ad-hoc signed: it runs on the build machine as-is, but other
# Macs will see a Gatekeeper prompt (right-click -> Open the first time).
# Proper Developer ID signing + notarization needs an Apple Developer account.
set -eu

VERSION=${1:-0.1.0}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Monotonic build number so update tooling can order releases.
BUILD_NUMBER=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
DIST="$ROOT/dist"
APP="$DIST/xVigil.app"

cd "$ROOT"

echo "Building release binary (universal)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/xVigil
else
    echo "Universal build unavailable; building for this machine's architecture only."
    swift build -c release >/dev/null
    BIN=$(swift build -c release --show-bin-path)/xVigil
fi

echo "Assembling ${APP#$ROOT/}…"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/xVigil"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>xVigil</string>
    <key>CFBundleIdentifier</key>             <string>io.github.serverwrestler.xVigil</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>xVigil</string>
    <key>CFBundleDisplayName</key>            <string>xVigil</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>         <string>15.0</string>
    <key>LSUIElement</key>                    <true/>
    <key>NSHumanReadableCopyright</key>       <string>MIT License</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP"

ZIP="$DIST/xVigil-$VERSION.zip"
echo "Zipping…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done:"
ls -lh "$ZIP" | awk '{print "  " $9 " (" $5 ")"}'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
