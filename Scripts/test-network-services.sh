#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/proxygauge-network-services-test.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/xcrun swiftc -target arm64-apple-macosx26.0 -module-cache-path "$STAGE/module-cache" -parse-as-library \
  "$PROJECT_ROOT/HelperSources/NetworkServiceSnapshot.swift" \
  "$PROJECT_ROOT/Tests/NetworkServiceSnapshotCheck.swift" -o "$STAGE/check"
"$STAGE/check"
# Build the real read-only adapter too, but do not consult the host VPN in tests.
/usr/bin/xcrun swiftc -target arm64-apple-macosx26.0 -module-cache-path "$STAGE/module-cache" -parse-as-library \
  "$PROJECT_ROOT/HelperSources/NetworkServiceSnapshot.swift" \
  "$PROJECT_ROOT/HelperSources/NetworkServicesMain.swift" -o "$STAGE/helper"
