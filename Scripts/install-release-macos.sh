#!/bin/bash
set -euo pipefail

REPOSITORY="ValenLan/ProxyGauge"
MINIMUM_MACOS_MAJOR=26
INSTALL_DIR="/Library/Application Support/ProxyGauge"
DESTINATION="$INSTALL_DIR/ProxyGauge.app"
APPLICATION_LINK="/Applications/ProxyGauge.app"
LEGACY_HOME_APP="$HOME/Applications/ProxyGauge.app"

OS_CHECK_ONLY=${PROXYGAUGE_INSTALLER_OS_CHECK_ONLY:-0}
TEST_PRODUCT_VERSION=${PROXYGAUGE_INSTALLER_TEST_PRODUCT_VERSION:-}
if [ "$OS_CHECK_ONLY" != 0 ] && [ "$OS_CHECK_ONLY" != 1 ]; then
  echo "无效的 macOS 兼容性检查参数。" >&2
  exit 1
fi
if [ -n "$TEST_PRODUCT_VERSION" ]; then
  if [ "$OS_CHECK_ONLY" != 1 ] || [ "$(/usr/bin/id -u)" -eq 0 ]; then
    echo "测试版 macOS 版本只能用于非管理员兼容性检查。" >&2
    exit 1
  fi
  # A pure injected policy check exits below without downloading or installing,
  # so it can run on an Intel macOS cross-compilation runner as well.
  MACOS_PRODUCT_VERSION=$TEST_PRODUCT_VERSION
else
  if [ "$(/usr/bin/uname -s)" != "Darwin" ] || [ "$(/usr/bin/uname -m)" != "arm64" ]; then
    echo "ProxyGauge 正式版仅支持 Apple Silicon Mac。" >&2
    exit 1
  fi
  MACOS_PRODUCT_VERSION=$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)
fi
if [[ ! "$MACOS_PRODUCT_VERSION" =~ ^([0-9]+)(\.[0-9]+){0,2}$ ]]; then
  echo "无法识别当前 macOS 版本：${MACOS_PRODUCT_VERSION:-未知}" >&2
  exit 1
fi
MACOS_MAJOR=$((10#${BASH_REMATCH[1]}))
if [ "$MACOS_MAJOR" -lt "$MINIMUM_MACOS_MAJOR" ]; then
  echo "ProxyGauge 正式版需要 macOS $MINIMUM_MACOS_MAJOR 或更高版本；当前为 macOS ${MACOS_PRODUCT_VERSION}。" >&2
  exit 1
fi
if [ "$OS_CHECK_ONLY" = 1 ]; then
  echo "macOS $MACOS_PRODUCT_VERSION 与 ProxyGauge 正式版兼容。"
  exit 0
fi

# BEGIN_PROXYGAUGE_RUNNING_INSTANCE_CHECK
proxygauge_running_pids_from_process_table() {
  local process_table selected_uid process_line process_uid process_pid executable_path bundle_path bundle_id
  process_table=${1:-}
  selected_uid=${2:-}
  [[ "$selected_uid" =~ ^[0-9]+$ ]] || return 1
  while IFS= read -r process_line; do
    IFS=$' \t' read -r process_uid process_pid executable_path <<< "$process_line"
    [[ "$process_uid" =~ ^[0-9]+$ ]] || continue
    [[ "$process_pid" =~ ^[1-9][0-9]*$ ]] || continue
    [ "$process_uid" = "$selected_uid" ] || continue
    case "$executable_path" in
      /*.app/Contents/MacOS/ProxyGauge) ;;
      *) continue ;;
    esac
    bundle_path=${executable_path%/Contents/MacOS/ProxyGauge}
    [ -f "$bundle_path/Contents/Info.plist" ] || continue
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$bundle_path/Contents/Info.plist" 2>/dev/null) || continue
    [ "$bundle_id" = com.valenlan.proxygauge ] || continue
    /usr/bin/printf '%s\n' "$process_pid"
  done <<< "$process_table"
  return 0
}

proxygauge_assert_no_running_instances() {
  local selected_uid process_table running_pids
  selected_uid=${1:-}
  if ! process_table=$(LC_ALL=C /bin/ps -axww -o uid= -o pid= -o comm= 2>/dev/null); then
    echo "无法检查当前运行的 ProxyGauge，安装已停止。请退出 ProxyGauge 后重试。" >&2
    return 1
  fi
  if ! running_pids=$(proxygauge_running_pids_from_process_table "$process_table" "$selected_uid"); then
    echo "无法识别安装用户，安装已停止。" >&2
    return 1
  fi
  if [ -n "$running_pids" ]; then
    running_pids=${running_pids//$'\n'/, }
    echo "ProxyGauge 仍在运行（PID：${running_pids}）。请先退出 ProxyGauge，再重新运行安装命令；安装器不会强制结束进程。" >&2
    return 1
  fi
  return 0
}
# END_PROXYGAUGE_RUNNING_INSTANCE_CHECK

INSTALLING_USER_ID=$(/usr/bin/id -u)
proxygauge_assert_no_running_instances "$INSTALLING_USER_ID"

TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-release.XXXXXX")
cleanup() {
  status=$?
  trap - EXIT
  /bin/rm -rf "$TEMP_DIR"
  exit "$status"
}
trap cleanup EXIT

REQUESTED_VERSION=${PROXYGAUGE_VERSION:-}
if [ -n "$REQUESTED_VERSION" ]; then
  if [[ ! "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无效的 ProxyGauge 指定版本：$REQUESTED_VERSION" >&2
    exit 1
  fi
  VERSION=$REQUESTED_VERSION
  TAG="v$VERSION"
else
  LATEST_URL=$(/usr/bin/curl -q \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --location \
    --silent \
    --show-error \
    --fail \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 45 \
    --speed-limit 1024 \
    --speed-time 30 \
    --output /dev/null \
    --write-out '%{url_effective}' \
    "https://github.com/$REPOSITORY/releases/latest")
  TAG=${LATEST_URL##*/}

  if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无法从 GitHub 识别最新正式版标签：$TAG" >&2
    exit 1
  fi
  if [ "$LATEST_URL" != "https://github.com/$REPOSITORY/releases/tag/$TAG" ]; then
    echo "GitHub 最新正式版跳转到了非预期地址：$LATEST_URL" >&2
    exit 1
  fi
  VERSION=${TAG#v}
fi

ASSET="ProxyGauge-$VERSION-macOS-arm64.zip"
RELEASE_BASE="https://github.com/$REPOSITORY/releases/download/$TAG"
ARCHIVE="$TEMP_DIR/$ASSET"
CHECKSUMS="$TEMP_DIR/SHA256SUMS.txt"

download() {
  source_url=$1
  destination_path=$2
  maximum_bytes=$3
  /usr/bin/curl -q \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --location \
    --silent \
    --show-error \
    --fail \
    --retry 3 \
    --connect-timeout 15 \
    --max-time 300 \
    --speed-limit 1024 \
    --speed-time 30 \
    --max-filesize "$maximum_bytes" \
    --output "$destination_path" \
    "$source_url"
}

echo "正在下载 ProxyGauge $TAG 正式版…"
download "$RELEASE_BASE/SHA256SUMS.txt" "$CHECKSUMS" 1048576

EXPECTED_SHA=$(/usr/bin/awk -v asset="$ASSET" '
  length($1) == 64 && $1 ~ /^[0-9A-Fa-f]+$/ {
    name = $2
    sub(/^\*/, "", name)
    if (name == asset) {
      found = tolower($1)
      count++
    }
  }
  END {
    if (count == 1) print found
    else exit 1
  }
' "$CHECKSUMS") || {
  echo "SHA256SUMS.txt 必须包含唯一的 $ASSET 校验值。" >&2
  exit 1
}
download "$RELEASE_BASE/$ASSET" "$ARCHIVE" 536870912
ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print tolower($1) }')

if [ -z "$EXPECTED_SHA" ] || [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "SHA-256 校验失败，安装已停止。" >&2
  exit 1
fi

EXTRACT_DIR="$TEMP_DIR/extracted"
/bin/mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/ProxyGauge.app"

if [ ! -x "$EXTRACTED_APP/Contents/MacOS/ProxyGauge" ]; then
  echo "正式版压缩包缺少可执行的 ProxyGauge.app。" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$EXTRACTED_APP/Contents/Info.plist")
if [ "$BUNDLE_VERSION" != "$VERSION" ]; then
  echo "App 版本 $BUNDLE_VERSION 与正式版标签 $TAG 不一致。" >&2
  exit 1
fi

ROOT_INSTALL_SCRIPT=""
IFS= read -r -d '' ROOT_INSTALL_SCRIPT <<'ROOT_INSTALL' || true
set -euo pipefail
umask 077

archive_source=${1:-}
archive_expected=${2:-}
version=${3:-}
installing_user_id=${4:-}
install_dir='/Library/Application Support/ProxyGauge'
destination="$install_dir/ProxyGauge.app"
application_link=/Applications/ProxyGauge.app

[ "${#archive_expected}" -eq 64 ] || exit 2
case "$archive_expected" in *[!0-9A-Fa-f]*) exit 2 ;; esac
case "$version" in ''|*[!0-9.]*|.*|*..*|*.) exit 2 ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[ -f "$archive_source" ] && [ ! -L "$archive_source" ] || exit 2
[[ "$installing_user_id" =~ ^[0-9]+$ ]] || exit 2
proxygauge_assert_no_running_instances "$installing_user_id"

stage=$(/usr/bin/mktemp -d /private/var/tmp/com.valenlan.proxygauge-install.XXXXXX)
install_stage=
backup_app=
previous_link="$stage/ProxyGauge.previous-link.app"
had_destination=0
had_application_link=0
app_transaction_started=0
link_transaction_started=0
committed=0
cleanup_root() {
  status=$?
  preserve_stage=0
  preserve_install_stage=0
  trap - EXIT HUP INT TERM
  if [ "$committed" -ne 1 ]; then
    if [ -e "$previous_link" ] || [ -L "$previous_link" ]; then
      if ! /bin/rm -rf "$application_link" \
        || ! /bin/mv "$previous_link" "$application_link"; then
        status=1
        preserve_stage=1
      fi
    elif [ "$link_transaction_started" -eq 1 ] && [ "$had_application_link" -eq 0 ]; then
      /bin/rm -rf "$application_link" || status=1
    fi
    if [ -n "$backup_app" ] && { [ -e "$backup_app" ] || [ -L "$backup_app" ]; }; then
      if ! /bin/rm -rf "$destination" \
        || ! /bin/mv "$backup_app" "$destination"; then
        status=1
        preserve_install_stage=1
      fi
    elif [ "$app_transaction_started" -eq 1 ] && [ "$had_destination" -eq 0 ]; then
      /bin/rm -rf "$destination" || status=1
    fi
  fi
  if [ -n "$install_stage" ]; then
    if [ "$preserve_install_stage" -eq 1 ] \
      || { [ -n "$backup_app" ] && { [ -e "$backup_app" ] || [ -L "$backup_app" ]; }; }; then
      echo "旧版本恢复失败；可恢复副本保留在受保护目录：$install_stage" >&2
    else
      /bin/rm -rf "$install_stage" || status=1
    fi
  fi
  if [ "$preserve_stage" -eq 1 ] || [ -e "$previous_link" ] || [ -L "$previous_link" ]; then
    echo "旧应用入口恢复失败；可恢复副本保留在受保护目录：$stage" >&2
  else
    /bin/rm -rf "$stage" || status=1
  fi
  exit "$status"
}
trap cleanup_root EXIT HUP INT TERM

staged_archive="$stage/ProxyGauge-release.zip"
/usr/bin/install -o root -g wheel -m 600 "$archive_source" "$staged_archive"
actual=$(/usr/bin/shasum -a 256 "$staged_archive" | /usr/bin/awk '{print $1}')
[ "$(/usr/bin/printf '%s' "$actual" | /usr/bin/tr '[:upper:]' '[:lower:]')" = \
  "$(/usr/bin/printf '%s' "$archive_expected" | /usr/bin/tr '[:upper:]' '[:lower:]')" ] || {
  echo 'SHA-256 校验失败，安装已停止。' >&2
  exit 1
}

extract_dir="$stage/extracted"
/bin/mkdir "$extract_dir"
/usr/bin/ditto -x -k "$staged_archive" "$extract_dir"
extracted_app="$extract_dir/ProxyGauge.app"
[ -x "$extracted_app/Contents/MacOS/ProxyGauge" ] || exit 1
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extracted_app/Contents/Info.plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extracted_app/Contents/Info.plist")
[ "$bundle_id" = com.valenlan.proxygauge ] && [ "$bundle_version" = "$version" ] || exit 1
/usr/bin/codesign --verify --deep --strict --verbose=2 "$extracted_app"
if /usr/bin/find "$extracted_app" -type l -print -quit | /usr/bin/grep -q .; then
  echo '更新包包含不受支持的符号链接，安装已停止。' >&2
  exit 1
fi

for parent in /Library '/Library/Application Support'; do
  [ -d "$parent" ] && [ ! -L "$parent" ] || exit 1
  [ "$(/usr/bin/stat -f '%u' "$parent")" = 0 ] || exit 1
  parent_mode=$(/usr/bin/stat -f '%Lp' "$parent")
  [ $((8#$parent_mode & 022)) -eq 0 ] || exit 1
  parent_acl=$(/bin/ls -lde "$parent" | /usr/bin/awk 'NR == 1 { print $1 }')
  case "$parent_acl" in *+*) echo '正式安装父目录包含扩展 ACL，安装已停止。' >&2; exit 1 ;; esac
done
if [ ! -e "$install_dir" ]; then
  /usr/bin/install -d -o root -g wheel -m 755 "$install_dir"
fi
[ -d "$install_dir" ] && [ ! -L "$install_dir" ] || exit 1
/bin/chmod -N "$install_dir"
/usr/sbin/chown root:wheel "$install_dir"
/bin/chmod 755 "$install_dir"

install_stage=$(/usr/bin/mktemp -d "$install_dir/.install.XXXXXX")
staged_app="$install_stage/ProxyGauge.app"
/usr/bin/ditto "$extracted_app" "$staged_app"
/bin/chmod -RN "$staged_app"
/usr/sbin/chown -R root:wheel "$staged_app"
/bin/chmod -R go-w "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"

proxygauge_assert_no_running_instances "$installing_user_id"
backup_app="$install_stage/ProxyGauge.previous.app"
if [ -e "$destination" ] || [ -L "$destination" ]; then
  had_destination=1
  [ ! -L "$destination" ] && [ -d "$destination" ] || exit 1
  /bin/mv "$destination" "$backup_app"
fi
app_transaction_started=1
/bin/mv "$staged_app" "$destination"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"

if [ -e "$application_link" ] || [ -L "$application_link" ]; then
  had_application_link=1
  /bin/mv "$application_link" "$previous_link"
fi
link_transaction_started=1
/bin/ln -s "$destination" "$application_link"
[ "$(/usr/bin/readlink "$application_link")" = "$destination" ] || exit 1
committed=1
/bin/rm -rf "$backup_app" "$previous_link" "$install_stage"
install_stage=
ROOT_INSTALL
ROOT_INSTALL_SCRIPT="$(builtin declare -f proxygauge_running_pids_from_process_table)
$(builtin declare -f proxygauge_assert_no_running_instances)
$ROOT_INSTALL_SCRIPT"

ADMIN_APPLESCRIPT=""
IFS= read -r -d '' ADMIN_APPLESCRIPT <<'ADMIN_APPLESCRIPT_BODY' || true
use scripting additions
on run argv
    if (count of argv) is not 5 then error "Invalid ProxyGauge installer arguments"
    set bootstrapText to item 1 of argv
    set archivePath to item 2 of argv
    set archiveHash to item 3 of argv
    set releaseVersion to item 4 of argv
    set installingUserID to item 5 of argv
    set commandText to "/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.install.lock /bin/bash -p -c " & quoted form of bootstrapText & " proxygauge-install-bootstrap " & quoted form of archivePath & " " & quoted form of archiveHash & " " & quoted form of releaseVersion & " " & quoted form of installingUserID
    «event sysoexec» commandText given «class badm»:true
end run
ADMIN_APPLESCRIPT_BODY

proxygauge_assert_no_running_instances "$INSTALLING_USER_ID"
if ! /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  /usr/bin/osascript -e "$ADMIN_APPLESCRIPT" -- \
  "$ROOT_INSTALL_SCRIPT" "$ARCHIVE" "$EXPECTED_SHA" "$VERSION" "$INSTALLING_USER_ID"; then
  echo "管理员安装失败或已取消，未替换正式版本。" >&2
  exit 1
fi

if [ -e "$LEGACY_HOME_APP" ] || [ -L "$LEGACY_HOME_APP" ]; then
  /bin/mv "$LEGACY_HOME_APP" "$TEMP_DIR/ProxyGauge.legacy-home.app"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APPLICATION_LINK" >/dev/null 2>&1 || true

echo "已安装 ProxyGauge $TAG：$DESTINATION"
echo "可从 $APPLICATION_LINK 打开；应用本体位于受保护的系统目录。"
echo "当前正式版采用 ad-hoc 签名且尚未公证；脚本不会绕过 macOS 安全检查。"
