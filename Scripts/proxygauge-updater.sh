#!/bin/bash
set -euo pipefail

ARCHIVE=${1:-}
EXPECTED_SHA=${2:-}
VERSION=${3:-}
DESTINATION=${4:-}
APP_PID=${5:-}
USER_ID=${6:-}
READY_MARKER=${7:-}
READY_NONCE=${8:-}
TEST_MODE=${PROXYGAUGE_UPDATER_TEST_MODE:-0}
TEST_FAIL_FINAL_VERIFY=${PROXYGAUGE_UPDATER_TEST_FAIL_FINAL_VERIFY:-0}
TEST_FAIL_ROLLBACK_MOVE=${PROXYGAUGE_UPDATER_TEST_FAIL_ROLLBACK_MOVE:-0}

if [ "$#" -ne 8 ]; then
  echo "无效的更新参数。" >&2
  exit 2
fi

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
if ! [[ "$READY_NONCE" =~ ^[0-9a-f]{64}$ ]] \
  || [ "$(/usr/bin/basename "$READY_MARKER")" != "ready" ]; then
  echo "无效的更新就绪握手参数。" >&2
  exit 2
fi
READY_DIR=$(/usr/bin/dirname "$READY_MARKER")
if [ ! -d "$READY_DIR" ] || [ -L "$READY_DIR" ]; then
  echo "更新就绪握手目录不存在或不安全。" >&2
  exit 2
fi
CURRENT_UID=$(/usr/bin/id -u)
if [ "$(/usr/bin/stat -f '%u' "$READY_DIR" 2>/dev/null || true)" != "$CURRENT_UID" ]; then
  echo "更新就绪握手目录所有者不安全。" >&2
  exit 2
fi
READY_DIR_MODE=$(/usr/bin/stat -f '%Lp' "$READY_DIR" 2>/dev/null || true)
if [ -z "$READY_DIR_MODE" ] || [ $((8#$READY_DIR_MODE & 022)) -ne 0 ]; then
  echo "更新就绪握手目录权限不安全。" >&2
  exit 2
fi
if [ -e "$READY_MARKER" ] || [ -L "$READY_MARKER" ]; then
  echo "更新就绪标记已存在。" >&2
  exit 2
fi
if [ "$TEST_MODE" = 1 ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "测试模式不得以管理员身份运行。" >&2
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
if [ "$(/usr/bin/id -u)" -eq 0 ] \
  && [ "$DESTINATION" != "/Library/Application Support/ProxyGauge/ProxyGauge.app" ]; then
  echo "管理员更新目标不是受保护的正式安装目录。" >&2
  exit 2
fi

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  LOG_DIR=/var/log/ProxyGauge
  if [ ! -e "$LOG_DIR" ]; then
    /usr/bin/install -d -o root -g wheel -m 755 "$LOG_DIR"
  fi
  if [ ! -d "$LOG_DIR" ] || [ -L "$LOG_DIR" ] \
    || [ "$(/usr/bin/stat -f '%u' "$LOG_DIR" 2>/dev/null || true)" != 0 ]; then
    echo "更新日志目录不安全。" >&2
    exit 1
  fi
  LOG_DIR_MODE=$(/usr/bin/stat -f '%Lp' "$LOG_DIR" 2>/dev/null || true)
  if [ -z "$LOG_DIR_MODE" ] || [ $((8#$LOG_DIR_MODE & 022)) -ne 0 ]; then
    echo "更新日志目录权限不安全。" >&2
    exit 1
  fi
  case "$(/bin/ls -lde "$LOG_DIR" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1 }')" in
    *+*) echo "更新日志目录包含不安全的扩展 ACL。" >&2; exit 1 ;;
  esac
elif [ "$TEST_MODE" = 1 ]; then
  LOG_DIR="$DESTINATION_PARENT/.proxygauge-test-logs"
  /bin/mkdir -p "$LOG_DIR"
else
  LOG_DIR="$HOME/Library/Logs/ProxyGauge"
  /bin/mkdir -p "$LOG_DIR" 2>/dev/null || true
fi
LOG_FILE="$LOG_DIR/update.log"
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  if [ -e "$LOG_FILE" ]; then
    if [ ! -f "$LOG_FILE" ] || [ -L "$LOG_FILE" ] \
      || [ "$(/usr/bin/stat -f '%u' "$LOG_FILE" 2>/dev/null || true)" != 0 ]; then
      echo "更新日志文件不安全。" >&2
      exit 1
    fi
    LOG_FILE_MODE=$(/usr/bin/stat -f '%Lp' "$LOG_FILE" 2>/dev/null || true)
    if [ -z "$LOG_FILE_MODE" ] || [ $((8#$LOG_FILE_MODE & 077)) -ne 0 ]; then
      echo "更新日志文件权限不安全。" >&2
      exit 1
    fi
    case "$(/bin/ls -le "$LOG_FILE" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1 }')" in
      *+*) echo "更新日志文件包含不安全的扩展 ACL。" >&2; exit 1 ;;
    esac
  else
    /usr/bin/touch "$LOG_FILE"
    /usr/sbin/chown root:wheel "$LOG_FILE"
    /bin/chmod 600 "$LOG_FILE"
  fi
fi
exec >> "$LOG_FILE" 2>&1

echo "[$(/bin/date '+%F %T')] 开始安装 ProxyGauge v$VERSION"

ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print tolower($1) }')
if [ "$ACTUAL_SHA" != "$(/usr/bin/printf '%s' "$EXPECTED_SHA" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]; then
  echo "更新包 SHA-256 校验失败。" >&2
  exit 1
fi

STAGE_DIR=$(/usr/bin/mktemp -d "$DESTINATION_PARENT/.proxygauge-update.XXXXXX")
BACKUP_APP="$STAGE_DIR/ProxyGauge.previous.app"
EXTRACT_DIR="$STAGE_DIR/extracted"
INSTALLED=0
TRANSACTION_STARTED=0
READY_TEMP=

cleanup() {
  status=$?
  preserve_stage=0
  trap - EXIT HUP INT TERM
  if [ -n "$READY_TEMP" ]; then
    /bin/rm -f "$READY_TEMP"
  fi
  /bin/rm -f "$READY_MARKER"
  /bin/rmdir "$READY_DIR" 2>/dev/null || true
  if [ "$INSTALLED" -ne 1 ]; then
    if [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; then
      if ! /bin/rm -rf "$DESTINATION"; then
        status=1
        preserve_stage=1
      elif [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_ROLLBACK_MOVE" = 1 ]; then
        echo "已注入旧版本恢复失败。" >&2
        status=1
        preserve_stage=1
      elif ! /bin/mv "$BACKUP_APP" "$DESTINATION"; then
        status=1
        preserve_stage=1
      fi
    elif [ "$TRANSACTION_STARTED" -eq 1 ]; then
      /bin/rm -rf "$DESTINATION" || status=1
    fi
  fi
  if [ "$preserve_stage" -eq 1 ] || [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; then
    echo "旧版本恢复失败；可恢复副本保留在：$STAGE_DIR" >&2
  else
    /bin/rm -rf "$STAGE_DIR" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    /bin/rm -f "$ARCHIVE"
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

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
if /usr/bin/find "$EXTRACTED_APP" -type l -print -quit | /usr/bin/grep -q .; then
  echo "更新包包含不受支持的符号链接。" >&2
  exit 1
fi
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  for protected_parent in /Library "/Library/Application Support" "$DESTINATION_PARENT"; do
    if [ ! -d "$protected_parent" ] || [ -L "$protected_parent" ] \
      || [ "$(/usr/bin/stat -f '%u' "$protected_parent" 2>/dev/null || true)" != 0 ]; then
      echo "正式安装目录的所有者或类型不安全。" >&2
      exit 1
    fi
    protected_mode=$(/usr/bin/stat -f '%Lp' "$protected_parent" 2>/dev/null || true)
    if [ -z "$protected_mode" ] || [ $((8#$protected_mode & 022)) -ne 0 ]; then
      echo "正式安装目录权限不安全。" >&2
      exit 1
    fi
  done
  /bin/chmod -N "$DESTINATION_PARENT"
  /usr/sbin/chown root:wheel "$DESTINATION_PARENT"
  /bin/chmod 755 "$DESTINATION_PARENT"
  /bin/chmod -RN "$EXTRACTED_APP"
  /usr/sbin/chown -R root:wheel "$EXTRACTED_APP"
  /bin/chmod -R go-w "$EXTRACTED_APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
fi

READY_TEMP="$READY_DIR/.ready.$$.tmp"
if [ -e "$READY_TEMP" ] || [ -L "$READY_TEMP" ]; then
  echo "更新就绪临时标记已存在。" >&2
  exit 1
fi
/usr/bin/printf '%s\n' "$READY_NONCE" > "$READY_TEMP"
if [ "$CURRENT_UID" -eq 0 ]; then
  /usr/sbin/chown root:wheel "$READY_TEMP"
  /bin/chmod 644 "$READY_TEMP"
else
  /bin/chmod 600 "$READY_TEMP"
fi
/bin/mv "$READY_TEMP" "$READY_MARKER"
READY_TEMP=

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

if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  /bin/mv "$DESTINATION" "$BACKUP_APP"
fi
TRANSACTION_STARTED=1
/bin/mv "$EXTRACTED_APP" "$DESTINATION"
if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_FINAL_VERIFY" = 1 ]; then
  echo "已注入最终校验失败。" >&2
  false
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION"
INSTALLED=1
/bin/rm -rf "$BACKUP_APP"

echo "[$(/bin/date '+%F %T')] 已安装 ProxyGauge v$VERSION"
if [ "$TEST_MODE" = 1 ]; then
  :
elif [ "$(/usr/bin/id -u)" -eq 0 ]; then
  /bin/launchctl asuser "$USER_ID" /usr/bin/open "$DESTINATION" || true
else
  /usr/bin/open "$DESTINATION" || true
fi
