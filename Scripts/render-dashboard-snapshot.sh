#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
OUTPUT=${1:-"$PROJECT_ROOT/build/dashboard-snapshot.png"}
STATE=${2:-dashboard}
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-dashboard-render.XXXXXX")
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
/bin/mkdir -p "$TEMP_ROOT/module-cache" "$PROJECT_ROOT/build"

cd "$PROJECT_ROOT"
/usr/bin/xcrun swiftc \
  -D SNAPSHOT \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  Sources/ProxyGaugeApp.swift \
  Sources/DashboardView.swift \
  Sources/ExitClipboard.swift \
  Sources/IPAddressVersion.swift \
  Sources/WindowCapability.swift \
  Sources/UpdateService.swift \
  Tests/DashboardSnapshot.swift \
  -o "$TEMP_ROOT/dashboard-renderer"
case "$STATE" in
  browser-prompt|browser-prompt-dark|connection-setup|connection-setup-dark|dashboard-dark|dashboard-ipv6|dashboard-ipv6-dark|dashboard-compact|dashboard-compact-dark|dashboard-wide|dashboard-wide-dark|dashboard-fullscreen|dashboard-fullscreen-dark)
    "$TEMP_ROOT/dashboard-renderer" "$OUTPUT" "$STATE"
    ;;
  *)
    "$TEMP_ROOT/dashboard-renderer" "$OUTPUT"
    ;;
esac

echo "Rendered $OUTPUT"
