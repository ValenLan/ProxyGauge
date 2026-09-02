#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
BUILD_DIR="$PROJECT_ROOT/build"
APP="$BUILD_DIR/ProxyGauge.app"
MODULE_CACHE="$BUILD_DIR/module-cache"
GENERATED_INTEGRITY="$BUILD_DIR/BundledResourceIntegrity.generated.swift"

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

BACKEND_SHA=$(/usr/bin/shasum -a 256 "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" | /usr/bin/awk '{print $1}')
KILLSWITCH_SHA=$(/usr/bin/shasum -a 256 "$PROJECT_ROOT/Scripts/proxygauge-killswitch" | /usr/bin/awk '{print $1}')
KILLSWITCH_TEMPLATE_SHA=$(/usr/bin/shasum -a 256 "$PROJECT_ROOT/PF/proxygauge.conf.template" | /usr/bin/awk '{print $1}')
UPDATER_SHA=$(/usr/bin/shasum -a 256 "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" | /usr/bin/awk '{print $1}')
/usr/bin/sed \
  -e "s/__UPDATE_BACKEND_SHA256__/$BACKEND_SHA/" \
  -e "s/__UPDATE_KILLSWITCH_SHA256__/$KILLSWITCH_SHA/" \
  -e "s/__UPDATE_KILLSWITCH_TEMPLATE_SHA256__/$KILLSWITCH_TEMPLATE_SHA/" \
  -e "s/__UPDATE_UPDATER_SHA256__/$UPDATER_SHA/" \
  "$PROJECT_ROOT/Sources/BundledResourceIntegrity.swift" > "$GENERATED_INTEGRITY"
if /usr/bin/grep -q '__UPDATE_' "$GENERATED_INTEGRITY"; then
  echo "Failed to generate bundled resource integrity manifest." >&2
  exit 1
fi

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$PROJECT_ROOT/Sources/BackendCommandRunner.swift" \
  "$GENERATED_INTEGRITY" \
  "$PROJECT_ROOT/Sources/ConnectionDetailFormatter.swift" \
  "$PROJECT_ROOT/Sources/KillSwitchAdminService.swift" \
  "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift" \
  "$PROJECT_ROOT/Sources/DashboardView.swift" \
  "$PROJECT_ROOT/Sources/ExitClipboard.swift" \
  "$PROJECT_ROOT/Sources/ExitSummaryService.swift" \
  "$PROJECT_ROOT/Sources/IPAddressVersion.swift" \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/WindowCapability.swift" \
  "$PROJECT_ROOT/Sources/UpdateService.swift" \
  -o "$APP/Contents/MacOS/ProxyGauge"

/bin/cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/ProxyGauge.icns" "$APP/Contents/Resources/ProxyGauge.icns"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" "$APP/Contents/Resources/proxygauge-backend.sh"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-check.sh" "$APP/Contents/Resources/proxygauge-check.sh"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-killswitch" "$APP/Contents/Resources/proxygauge-killswitch"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" "$APP/Contents/Resources/proxygauge-ip-risk.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" "$APP/Contents/Resources/proxygauge-chain-check.jxa"
/bin/cp "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" "$APP/Contents/Resources/proxygauge-updater.sh"
/bin/cp "$PROJECT_ROOT/PF/proxygauge.conf.template" "$APP/Contents/Resources/proxygauge.conf.template"
/bin/cp "$PROJECT_ROOT/Rules/ProxyGauge-Merge.yaml" "$APP/Contents/Resources/Rules/ProxyGauge-Merge.yaml"
/bin/cp "$PROJECT_ROOT/Rules/ProxyGauge-Google-Chain-Probe.yaml" "$APP/Contents/Resources/Rules/ProxyGauge-Google-Chain-Probe.yaml"
/bin/cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

verify_packaged_digest() {
  local expected actual packaged_path
  expected="$1"
  packaged_path="$2"
  actual=$(/usr/bin/shasum -a 256 "$packaged_path" | /usr/bin/awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "Bundled resource changed during build: $packaged_path" >&2
    exit 1
  fi
}
verify_packaged_digest "$BACKEND_SHA" "$APP/Contents/Resources/proxygauge-backend.sh"
verify_packaged_digest "$KILLSWITCH_SHA" "$APP/Contents/Resources/proxygauge-killswitch"
verify_packaged_digest "$KILLSWITCH_TEMPLATE_SHA" "$APP/Contents/Resources/proxygauge.conf.template"
verify_packaged_digest "$UPDATER_SHA" "$APP/Contents/Resources/proxygauge-updater.sh"

/bin/chmod 755 \
  "$APP/Contents/MacOS/ProxyGauge" \
  "$APP/Contents/Resources/proxygauge-backend.sh" \
  "$APP/Contents/Resources/proxygauge-check.sh" \
  "$APP/Contents/Resources/proxygauge-killswitch" \
  "$APP/Contents/Resources/proxygauge-ip-risk.jxa" \
  "$APP/Contents/Resources/proxygauge-chain-check.jxa" \
  "$APP/Contents/Resources/proxygauge-updater.sh"

for required_path in \
  "$APP/Contents/Resources/proxygauge-check.sh" \
  "$APP/Contents/Resources/proxygauge-killswitch" \
  "$APP/Contents/Resources/proxygauge-ip-risk.jxa" \
  "$APP/Contents/Resources/proxygauge-chain-check.jxa" \
  "$APP/Contents/Resources/proxygauge-updater.sh" \
  "$APP/Contents/Resources/proxygauge.conf.template" \
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
