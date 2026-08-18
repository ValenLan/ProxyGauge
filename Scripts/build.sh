#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/PuffRoute.app"

if [ -d "$APP" ]; then
  /bin/rm -rf "$APP"
fi

/bin/mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$BUILD_DIR/module-cache"

/usr/bin/xcrun swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/PuffRouteApp.swift" \
  -o "$APP/Contents/MacOS/PuffRoute"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/PuffRoute.icns" "$APP/Contents/Resources/PuffRoute.icns"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-backend.sh" "$APP/Contents/Resources/puffroute-backend.sh"
/bin/chmod 755 \
  "$APP/Contents/MacOS/PuffRoute" \
  "$APP/Contents/Resources/puffroute-backend.sh"

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
