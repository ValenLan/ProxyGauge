#!/bin/bash
set -euo pipefail

REPOSITORY="ValenLan/ProxyGauge"
INSTALL_DIR="$HOME/Applications"
DESTINATION="$INSTALL_DIR/ProxyGauge.app"
TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-release.XXXXXX")
STAGE_DIR=""
BACKUP_APP="$TEMP_DIR/ProxyGauge.previous.app"

cleanup() {
  status=$?
  trap - EXIT

  if { [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; } && \
     { [ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ]; }; then
    /bin/mv "$BACKUP_APP" "$DESTINATION" || true
  fi

  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    /bin/rm -rf "$STAGE_DIR"
  fi
  /bin/rm -rf "$TEMP_DIR"
  exit "$status"
}
trap cleanup EXIT

if [ "$(/usr/bin/uname -s)" != "Darwin" ] || [ "$(/usr/bin/uname -m)" != "arm64" ]; then
  echo "ProxyGauge 正式版仅支持 Apple Silicon Mac。" >&2
  exit 1
fi

REQUESTED_VERSION=${PROXYGAUGE_VERSION:-}
if [ -n "$REQUESTED_VERSION" ]; then
  if [[ ! "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无效的 ProxyGauge 指定版本：$REQUESTED_VERSION" >&2
    exit 1
  fi
  VERSION=$REQUESTED_VERSION
  TAG="v$VERSION"
else
  LATEST_URL=$(/usr/bin/curl \
    --proto '=https' \
    --tlsv1.2 \
    --location \
    --silent \
    --show-error \
    --fail \
    --retry 3 \
    --output /dev/null \
    --write-out '%{url_effective}' \
    "https://github.com/$REPOSITORY/releases/latest")
  TAG=${LATEST_URL##*/}

  if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无法从 GitHub 识别最新正式版标签：$TAG" >&2
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
  /usr/bin/curl \
    --proto '=https' \
    --tlsv1.2 \
    --location \
    --silent \
    --show-error \
    --fail \
    --retry 3 \
    --output "$destination_path" \
    "$source_url"
}

echo "正在下载 ProxyGauge $TAG 正式版…"
download "$RELEASE_BASE/$ASSET" "$ARCHIVE"
download "$RELEASE_BASE/SHA256SUMS.txt" "$CHECKSUMS"

EXPECTED_SHA=$(/usr/bin/awk -v asset="$ASSET" '
  length($1) == 64 && $1 ~ /^[0-9A-Fa-f]+$/ {
    name = $2
    sub(/^\*/, "", name)
    if (name == asset) {
      print tolower($1)
      exit
    }
  }
' "$CHECKSUMS")
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

/bin/mkdir -p "$INSTALL_DIR"
STAGE_DIR=$(/usr/bin/mktemp -d "$INSTALL_DIR/.proxygauge-install.XXXXXX")
STAGED_APP="$STAGE_DIR/ProxyGauge.app"
/usr/bin/ditto "$EXTRACTED_APP" "$STAGED_APP"

if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  /bin/mv "$DESTINATION" "$BACKUP_APP"
fi

/bin/mv "$STAGED_APP" "$DESTINATION"
if [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; then
  /bin/rm -rf "$BACKUP_APP"
fi

echo "已安装 ProxyGauge $TAG：$DESTINATION"
echo "可在 Finder 的个人目录 → Applications 中打开。"
echo "当前正式版采用 ad-hoc 签名且尚未公证；脚本不会绕过 macOS 安全检查。"
