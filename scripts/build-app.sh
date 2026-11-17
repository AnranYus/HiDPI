#!/bin/sh
# Builds build/HiDPI.app (universal, ad-hoc signed).
#   ./scripts/build-app.sh            build
#   ./scripts/build-app.sh --install  build and copy to /Applications
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/HiDPI"

APP=build/HiDPI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HiDPI"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "HiDPI"' 2>/dev/null || true
    rm -rf /Applications/HiDPI.app
    cp -R "$APP" /Applications/
    echo "installed /Applications/HiDPI.app"
fi
