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
  "$APP/Contents/Resources/AdminHelpers" \
  "$APP/Contents/Resources/Rules" \
  "$BUILD_DIR/module-cache"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/PuffRouteApp.swift" \
  -o "$APP/Contents/MacOS/PuffRoute"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/PuffRoute.icns" "$APP/Contents/Resources/PuffRoute.icns"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-backend.sh" "$APP/Contents/Resources/puffroute-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-check.sh" "$APP/Contents/Resources/puffroute-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-killswitch" "$APP/Contents/Resources/puffroute-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-ip-risk.jxa" "$APP/Contents/Resources/puffroute-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-chain-check.jxa" "$APP/Contents/Resources/puffroute-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/puffroute-private-browser.sh" "$APP/Contents/Resources/puffroute-private-browser.sh"
/bin/cp "$PROJECT_ROOT/Rules/PuffRoute-Merge.yaml" "$APP/Contents/Resources/Rules/PuffRoute-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/PuffRoute-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/PuffRoute-Google-Chain-Probe.yaml"

for action in On Off Status; do
  /usr/bin/osacompile -l AppleScript \
    -o "$APP/Contents/Resources/AdminHelpers/PuffRoute Admin $action.app" \
    "$PROJECT_ROOT/Helpers/PuffRoute Admin $action.applescript"
done

/bin/chmod 755 \
  "$APP/Contents/MacOS/PuffRoute" \
  "$APP/Contents/Resources/puffroute-backend.sh" \
  "$APP/Contents/Resources/puffroute-check.sh" \
  "$APP/Contents/Resources/puffroute-killswitch" \
  "$APP/Contents/Resources/puffroute-ip-risk.jxa" \
  "$APP/Contents/Resources/puffroute-chain-check.jxa" \
  "$APP/Contents/Resources/puffroute-private-browser.sh"

for required_path in \
  "$APP/Contents/Resources/puffroute-check.sh" \
  "$APP/Contents/Resources/puffroute-killswitch" \
  "$APP/Contents/Resources/puffroute-ip-risk.jxa" \
  "$APP/Contents/Resources/puffroute-chain-check.jxa" \
  "$APP/Contents/Resources/puffroute-private-browser.sh" \
  "$APP/Contents/Resources/Rules/PuffRoute-Merge.yaml" \
  "$APP/Contents/Resources/Rules/PuffRoute-Google-Chain-Probe.yaml" \
  "$APP/Contents/Resources/AdminHelpers/PuffRoute Admin On.app" \
  "$APP/Contents/Resources/AdminHelpers/PuffRoute Admin Off.app" \
  "$APP/Contents/Resources/AdminHelpers/PuffRoute Admin Status.app"; do
  if [ ! -e "$required_path" ]; then
    echo "Missing required bundled component: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
