#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-updater-test.XXXXXX")
/bin/mkdir -p "$TEMP_ROOT/module-cache"
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

/bin/bash -n "$PROJECT_ROOT/Scripts/proxygauge-updater.sh"

if "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" >/dev/null 2>&1; then
  echo 'Updater must reject incomplete arguments.' >&2
  exit 1
fi

/bin/cat > "$TEMP_ROOT/UpdaterTests.swift" <<'SWIFT'
import Foundation

@main
struct UpdaterTests {
    static func main() {
        precondition(AppVersion.compare("1.6.0", "1.5.7") == .orderedDescending)
        precondition(AppVersion.compare("1.5.7", "1.5.7") == .orderedSame)
        precondition(AppVersion.isValid("2.0.1"))
        precondition(!AppVersion.isValid("2.0"))
        let digest = String(repeating: "a", count: 64)
        let checksums = "\(digest)  ProxyGauge-1.6.0-macOS-arm64.zip\n"
        precondition(AppUpdateService.checksum(
            for: "ProxyGauge-1.6.0-macOS-arm64.zip",
            in: checksums
        ) == digest)
        precondition(AppUpdateService.checksum(for: "other.zip", in: checksums) == nil)
    }
}
SWIFT

/usr/bin/xcrun swiftc \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/UpdateService.swift" \
  "$TEMP_ROOT/UpdaterTests.swift" \
  -o "$TEMP_ROOT/updater-tests"
"$TEMP_ROOT/updater-tests"

echo 'ProxyGauge updater tests passed.'
