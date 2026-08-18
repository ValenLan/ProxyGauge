#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/CloudRoute.app"

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
  "$PROJECT_ROOT/Sources/CloudRouteApp.swift" \
  -o "$APP/Contents/MacOS/CloudRoute"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/CloudRoute.icns" "$APP/Contents/Resources/CloudRoute.icns"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-backend.sh" "$APP/Contents/Resources/cloudroute-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-check.sh" "$APP/Contents/Resources/cloudroute-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-killswitch" "$APP/Contents/Resources/cloudroute-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-ip-risk.jxa" "$APP/Contents/Resources/cloudroute-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-chain-check.jxa" "$APP/Contents/Resources/cloudroute-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudroute-private-browser.sh" "$APP/Contents/Resources/cloudroute-private-browser.sh"
/bin/cp "$PROJECT_ROOT/Rules/CloudRoute-Merge.yaml" "$APP/Contents/Resources/Rules/CloudRoute-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/CloudRoute-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/CloudRoute-Google-Chain-Probe.yaml"

for action in On Off Status; do
  /usr/bin/osacompile -l AppleScript \
    -o "$APP/Contents/Resources/AdminHelpers/CloudRoute Admin $action.app" \
    "$PROJECT_ROOT/Helpers/CloudRoute Admin $action.applescript"
done

/bin/chmod 755 \
  "$APP/Contents/MacOS/CloudRoute" \
  "$APP/Contents/Resources/cloudroute-backend.sh" \
  "$APP/Contents/Resources/cloudroute-check.sh" \
  "$APP/Contents/Resources/cloudroute-killswitch" \
  "$APP/Contents/Resources/cloudroute-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudroute-chain-check.jxa" \
  "$APP/Contents/Resources/cloudroute-private-browser.sh"

for required_path in \
  "$APP/Contents/Resources/cloudroute-check.sh" \
  "$APP/Contents/Resources/cloudroute-killswitch" \
  "$APP/Contents/Resources/cloudroute-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudroute-chain-check.jxa" \
  "$APP/Contents/Resources/cloudroute-private-browser.sh" \
  "$APP/Contents/Resources/Rules/CloudRoute-Merge.yaml" \
  "$APP/Contents/Resources/Rules/CloudRoute-Google-Chain-Probe.yaml" \
  "$APP/Contents/Resources/AdminHelpers/CloudRoute Admin On.app" \
  "$APP/Contents/Resources/AdminHelpers/CloudRoute Admin Off.app" \
  "$APP/Contents/Resources/AdminHelpers/CloudRoute Admin Status.app"; do
  if [ ! -e "$required_path" ]; then
    echo "Missing required bundled component: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
