#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-exit-initialization.XXXXXX")
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT
/usr/bin/xcrun swiftc -D SNAPSHOT -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" -parse-as-library \
  "$PROJECT_ROOT"/Sources/*.swift "$PROJECT_ROOT/Tests/ExitInitializationCheck.swift" \
  -o "$TEMP_ROOT/exit-initialization-check"
"$TEMP_ROOT/exit-initialization-check"
