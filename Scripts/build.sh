#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/CloudLink Guard.app"

if [ -d "$APP" ]; then
  /bin/rm -rf "$APP"
fi

/bin/mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Rules" \
  "$BUILD_DIR/module-cache"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/CloudLinkGuardApp.swift" \
  -o "$APP/Contents/MacOS/CloudLinkGuard"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/CloudLinkGuard.icns" "$APP/Contents/Resources/CloudLinkGuard.icns"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-backend.sh" "$APP/Contents/Resources/cloudlink-guard-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-check.sh" "$APP/Contents/Resources/cloudlink-guard-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-killswitch" "$APP/Contents/Resources/cloudlink-guard-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-ip-risk.jxa" "$APP/Contents/Resources/cloudlink-guard-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-chain-check.jxa" "$APP/Contents/Resources/cloudlink-guard-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudlink-guard-private-browser.sh" "$APP/Contents/Resources/cloudlink-guard-private-browser.sh"
/bin/cp "$PROJECT_ROOT/Rules/CloudLinkGuard-Merge.yaml" "$APP/Contents/Resources/Rules/CloudLinkGuard-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/CloudLinkGuard-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/CloudLinkGuard-Google-Chain-Probe.yaml"
/bin/cp "$PROJECT_ROOT/Helpers/CloudLinkGuard Admin.applescript" \
  "$APP/Contents/Resources/cloudlink-guard-admin.applescript"

/bin/chmod 755 \
  "$APP/Contents/MacOS/CloudLinkGuard" \
  "$APP/Contents/Resources/cloudlink-guard-backend.sh" \
  "$APP/Contents/Resources/cloudlink-guard-check.sh" \
  "$APP/Contents/Resources/cloudlink-guard-killswitch" \
  "$APP/Contents/Resources/cloudlink-guard-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudlink-guard-chain-check.jxa" \
  "$APP/Contents/Resources/cloudlink-guard-private-browser.sh"

for required_path in \
  "$APP/Contents/Resources/cloudlink-guard-check.sh" \
  "$APP/Contents/Resources/cloudlink-guard-killswitch" \
  "$APP/Contents/Resources/cloudlink-guard-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudlink-guard-chain-check.jxa" \
  "$APP/Contents/Resources/cloudlink-guard-private-browser.sh" \
  "$APP/Contents/Resources/cloudlink-guard-admin.applescript" \
  "$APP/Contents/Resources/Rules/CloudLinkGuard-Merge.yaml" \
  "$APP/Contents/Resources/Rules/CloudLinkGuard-Google-Chain-Probe.yaml"; do
  if [ ! -e "$required_path" ]; then
    echo "Missing required bundled component: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
