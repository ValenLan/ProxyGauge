#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-exit-lifecycle.XXXXXX")
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT
/usr/bin/xcrun swiftc -D SNAPSHOT -D LIFECYCLE_TESTS -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" -parse-as-library \
  "$PROJECT_ROOT"/Sources/*.swift "$PROJECT_ROOT/Tests/ExitInitializationCheck.swift" "$PROJECT_ROOT/Tests/ExitLifecycleCheck.swift" \
  -o "$TEMP_ROOT/exit-lifecycle-check"
python3 - "$TEMP_ROOT/exit-lifecycle-check" <<'PYRUN'
import subprocess,sys
try:
    result=subprocess.run([sys.argv[1]],timeout=30)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print("Exit lifecycle test exceeded its bounded deadline.",file=sys.stderr)
    sys.exit(124)
PYRUN
