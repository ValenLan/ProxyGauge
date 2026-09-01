#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-clipboard-test.XXXXXX")
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
/bin/mkdir -p "$TEMP_ROOT/module-cache"

/usr/bin/xcrun swiftc \
  -D CLIPBOARD_CHECK \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/ExitClipboard.swift" \
  "$PROJECT_ROOT/Tests/ClipboardCheck.swift" \
  -o "$TEMP_ROOT/clipboard-check"

"$TEMP_ROOT/clipboard-check"
