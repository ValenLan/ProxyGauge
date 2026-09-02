#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP="$PROJECT_ROOT/build/ProxyGauge.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Info.plist")
DEFAULT_ARCHIVE="$PROJECT_ROOT/dist/ProxyGauge-$VERSION-macOS-arm64.zip"
ARCHIVE=${1:-$DEFAULT_ARCHIVE}

verify_release_app() {
  local candidate bundle_identifier bundle_version architectures
  candidate="$1"
  if [ ! -x "$candidate/Contents/MacOS/ProxyGauge" ]; then
    echo "Packaged app is missing its executable bit: $candidate" >&2
    exit 1
  fi
  bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$candidate/Contents/Info.plist")
  bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$candidate/Contents/Info.plist")
  architectures=$(/usr/bin/lipo -archs "$candidate/Contents/MacOS/ProxyGauge")
  if [ "$bundle_identifier" != "com.valenlan.proxygauge" ]; then
    echo "Unexpected app bundle identifier: $bundle_identifier" >&2
    exit 1
  fi
  if [ "$bundle_version" != "$VERSION" ]; then
    echo "App version $bundle_version does not match archive version $VERSION." >&2
    exit 1
  fi
  if [ "$architectures" != "arm64" ]; then
    echo "The macOS release must contain only arm64 code, found: $architectures" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate"
}

if [ ! -d "$APP" ]; then
  echo "Missing app bundle: $APP" >&2
  echo "Run Scripts/build.sh first." >&2
  exit 1
fi

ARCHIVE_DIR=$(/usr/bin/dirname "$ARCHIVE")
/bin/mkdir -p "$ARCHIVE_DIR"
if [ -d "$ARCHIVE" ] || [ -L "$ARCHIVE" ]; then
  echo "Archive destination must be a regular file path: $ARCHIVE" >&2
  exit 1
fi

PACKAGE_STAGE=$(/usr/bin/mktemp -d "$ARCHIVE_DIR/.proxygauge-package.XXXXXX")
cleanup() {
  /bin/rm -rf "$PACKAGE_STAGE"
}
trap cleanup EXIT

ARCHIVE_NAME=$(/usr/bin/basename "$ARCHIVE")
STAGED_ARCHIVE="$PACKAGE_STAGE/$ARCHIVE_NAME"
VERIFY_DIR="$PACKAGE_STAGE/verify"
/bin/mkdir "$VERIFY_DIR"

verify_release_app "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ARCHIVE"

/usr/bin/ditto -x -k "$STAGED_ARCHIVE" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/ProxyGauge.app"
verify_release_app "$EXTRACTED_APP"
/bin/mv -f "$STAGED_ARCHIVE" "$ARCHIVE"

echo "Packaged $ARCHIVE"
