#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/CloudCheck.app"
MODULE_CACHE="$BUILD_DIR/module-cache"

if [ -d "$APP" ]; then
  /bin/rm -rf "$APP"
fi
if [ -d "$MODULE_CACHE" ]; then
  /bin/rm -rf "$MODULE_CACHE"
fi

/bin/mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Rules" \
  "$MODULE_CACHE"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/CloudCheckApp.swift" \
  -o "$APP/Contents/MacOS/CloudCheck"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/CloudCheck.icns" "$APP/Contents/Resources/CloudCheck.icns"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-backend.sh" "$APP/Contents/Resources/cloudcheck-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-check.sh" "$APP/Contents/Resources/cloudcheck-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-killswitch" "$APP/Contents/Resources/cloudcheck-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-ip-risk.jxa" "$APP/Contents/Resources/cloudcheck-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-chain-check.jxa" "$APP/Contents/Resources/cloudcheck-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/cloudcheck-private-browser.sh" "$APP/Contents/Resources/cloudcheck-private-browser.sh"
/bin/cp "$PROJECT_ROOT/Rules/CloudCheck-Merge.yaml" "$APP/Contents/Resources/Rules/CloudCheck-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/CloudCheck-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/CloudCheck-Google-Chain-Probe.yaml"
/bin/cp "$PROJECT_ROOT/Helpers/CloudCheck Admin.applescript" \
  "$APP/Contents/Resources/cloudcheck-admin.applescript"

/bin/chmod 755 \
  "$APP/Contents/MacOS/CloudCheck" \
  "$APP/Contents/Resources/cloudcheck-backend.sh" \
  "$APP/Contents/Resources/cloudcheck-check.sh" \
  "$APP/Contents/Resources/cloudcheck-killswitch" \
  "$APP/Contents/Resources/cloudcheck-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudcheck-chain-check.jxa" \
  "$APP/Contents/Resources/cloudcheck-private-browser.sh"

for required_path in \
  "$APP/Contents/Resources/cloudcheck-check.sh" \
  "$APP/Contents/Resources/cloudcheck-killswitch" \
  "$APP/Contents/Resources/cloudcheck-ip-risk.jxa" \
  "$APP/Contents/Resources/cloudcheck-chain-check.jxa" \
  "$APP/Contents/Resources/cloudcheck-private-browser.sh" \
  "$APP/Contents/Resources/cloudcheck-admin.applescript" \
  "$APP/Contents/Resources/Rules/CloudCheck-Merge.yaml" \
  "$APP/Contents/Resources/Rules/CloudCheck-Google-Chain-Probe.yaml"; do
  if [ ! -e "$required_path" ]; then
    echo "Missing required bundled component: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
