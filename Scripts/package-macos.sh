#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP="$PROJECT_ROOT/build/PuffRoute.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Info.plist")
DEFAULT_ARCHIVE="$PROJECT_ROOT/dist/PuffRoute-$VERSION-macOS-arm64.zip"
ARCHIVE=${1:-$DEFAULT_ARCHIVE}

if [ ! -d "$APP" ]; then
  echo "Missing app bundle: $APP" >&2
  echo "Run Scripts/build.sh first." >&2
  exit 1
fi

ARCHIVE_DIR=$(/usr/bin/dirname "$ARCHIVE")
/bin/mkdir -p "$ARCHIVE_DIR"

if [ -e "$ARCHIVE" ]; then
  /bin/rm -f "$ARCHIVE"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

VERIFY_DIR=$(/usr/bin/mktemp -d /tmp/puffroute-package.XXXXXX)
cleanup() {
  /bin/rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/PuffRoute.app"

if [ ! -x "$EXTRACTED_APP/Contents/MacOS/PuffRoute" ]; then
  echo "Packaged app is missing its executable bit." >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"

echo "Packaged $ARCHIVE"
