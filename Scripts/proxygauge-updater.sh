#!/bin/bash
set -euo pipefail

ARCHIVE=${1:-}
EXPECTED_SHA=${2:-}
VERSION=${3:-}
DESTINATION=${4:-}
APP_PID=${5:-}
USER_ID=${6:-}

case "$VERSION" in
  ''|*[!0-9.]*|.*|*..*|*.) echo "无效的更新版本。" >&2; exit 2 ;;
esac
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "无效的更新版本。" >&2
  exit 2
fi
if ! [[ "$EXPECTED_SHA" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "无效的更新校验值。" >&2
  exit 2
fi
if ! [[ "$APP_PID" =~ ^[0-9]+$ ]] || ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
  echo "无效的更新进程参数。" >&2
  exit 2
fi
if [ ! -f "$ARCHIVE" ] || [ -L "$ARCHIVE" ]; then
  echo "更新包不存在或不安全。" >&2
  exit 2
fi
if [ "$(/usr/bin/basename "$DESTINATION")" != "ProxyGauge.app" ]; then
  echo "更新目标不是 ProxyGauge.app。" >&2
  exit 2
fi

DESTINATION_PARENT=$(/usr/bin/dirname "$DESTINATION")
if [ "$DESTINATION_PARENT" = "/" ] || [ ! -d "$DESTINATION_PARENT" ]; then
  echo "更新目标目录无效。" >&2
  exit 2
fi

LOG_HOME=${PROXYGAUGE_UPDATE_LOG_HOME:-$HOME}
LOG_DIR="$LOG_HOME/Library/Logs/ProxyGauge"
/bin/mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/update.log"
exec >> "$LOG_FILE" 2>&1

echo "[$(/bin/date '+%F %T')] 开始安装 ProxyGauge v$VERSION"

for _ in $(/usr/bin/seq 1 120); do
  if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.25
done
if /bin/kill -0 "$APP_PID" 2>/dev/null; then
  echo "ProxyGauge 未在等待时间内退出。" >&2
  exit 1
fi

ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print tolower($1) }')
if [ "$ACTUAL_SHA" != "$(/usr/bin/printf '%s' "$EXPECTED_SHA" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]; then
  echo "更新包 SHA-256 校验失败。" >&2
  exit 1
fi

STAGE_DIR=$(/usr/bin/mktemp -d "$DESTINATION_PARENT/.proxygauge-update.XXXXXX")
BACKUP_APP="$STAGE_DIR/ProxyGauge.previous.app"
EXTRACT_DIR="$STAGE_DIR/extracted"
INSTALLED=0

cleanup() {
  status=$?
  trap - EXIT
  if [ "$INSTALLED" -ne 1 ] && [ -e "$BACKUP_APP" ] && [ ! -e "$DESTINATION" ]; then
    /bin/mv "$BACKUP_APP" "$DESTINATION" || true
  fi
  /bin/rm -rf "$STAGE_DIR"
  if [ "$status" -eq 0 ]; then
    /bin/rm -f "$ARCHIVE"
  fi
  exit "$status"
}
trap cleanup EXIT

/bin/mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/ProxyGauge.app"

if [ ! -x "$EXTRACTED_APP/Contents/MacOS/ProxyGauge" ]; then
  echo "更新包缺少可执行的 ProxyGauge.app。" >&2
  exit 1
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTRACTED_APP/Contents/Info.plist")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTRACTED_APP/Contents/Info.plist")
if [ "$BUNDLE_ID" != "com.valenlan.proxygauge" ] || [ "$BUNDLE_VERSION" != "$VERSION" ]; then
  echo "更新包身份或版本不匹配。" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"

if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  /bin/mv "$DESTINATION" "$BACKUP_APP"
fi
/bin/mv "$EXTRACTED_APP" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION"
INSTALLED=1
/bin/rm -rf "$BACKUP_APP"

echo "[$(/bin/date '+%F %T')] 已安装 ProxyGauge v$VERSION"
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  /bin/launchctl asuser "$USER_ID" /usr/bin/open "$DESTINATION" || true
else
  /usr/bin/open "$DESTINATION" || true
fi
