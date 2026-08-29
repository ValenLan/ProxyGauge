#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/ProxyGauge.app"
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
  "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift" \
  -o "$APP/Contents/MacOS/ProxyGauge"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/ProxyGauge.icns" "$APP/Contents/Resources/ProxyGauge.icns"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" "$APP/Contents/Resources/proxygauge-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-check.sh" "$APP/Contents/Resources/proxygauge-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-killswitch" "$APP/Contents/Resources/proxygauge-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" "$APP/Contents/Resources/proxygauge-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" "$APP/Contents/Resources/proxygauge-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/PF/proxygauge.conf.template" "$APP/Contents/Resources/proxygauge.conf.template"
/bin/cp "$PROJECT_ROOT/Rules/ProxyGauge-Merge.yaml" "$APP/Contents/Resources/Rules/ProxyGauge-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/ProxyGauge-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/ProxyGauge-Google-Chain-Probe.yaml"
/bin/cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
/bin/cp "$PROJECT_ROOT/Helpers/ProxyGauge Admin.applescript" \
  "$APP/Contents/Resources/proxygauge-admin.applescript"

/bin/chmod 755 \
  "$APP/Contents/MacOS/ProxyGauge" \
  "$APP/Contents/Resources/proxygauge-backend.sh" \
  "$APP/Contents/Resources/proxygauge-check.sh" \
  "$APP/Contents/Resources/proxygauge-killswitch" \
  "$APP/Contents/Resources/proxygauge-ip-risk.jxa" \
  "$APP/Contents/Resources/proxygauge-chain-check.jxa"

for required_path in \
  "$APP/Contents/Resources/proxygauge-check.sh" \
  "$APP/Contents/Resources/proxygauge-killswitch" \
  "$APP/Contents/Resources/proxygauge-ip-risk.jxa" \
  "$APP/Contents/Resources/proxygauge-chain-check.jxa" \
  "$APP/Contents/Resources/proxygauge.conf.template" \
  "$APP/Contents/Resources/proxygauge-admin.applescript" \
  "$APP/Contents/Resources/LICENSE.txt" \
  "$APP/Contents/Resources/Rules/ProxyGauge-Merge.yaml" \
  "$APP/Contents/Resources/Rules/ProxyGauge-Google-Chain-Probe.yaml"; do
  if [ ! -e "$required_path" ]; then
    echo "Missing required bundled component: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
