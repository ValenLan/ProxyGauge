#!/bin/bash
set -euo pipefail

# Launch a separate Chrome instance for browser-based proxy checks. A temporary
# profile and a per-process proxy keep normal browser activity unchanged.

DEFAULT_CONFIG="$HOME/.config/cloudroute/config"
LEGACY_CONFIG="$HOME/.config/puffroute/config"
CONFIG_FILE="${CLOUDROUTE_CONFIG:-${PUFFROUTE_CONFIG:-$DEFAULT_CONFIG}}"
ENV_CLOUDROUTE_MIXED="${CLOUDROUTE_MIXED:-${PUFFROUTE_MIXED:-}}"
ENV_SECONDARY_MIXED="${CLOUDROUTE_SECONDARY_MIXED:-}"
ENV_SECONDARY_LABEL="${CLOUDROUTE_SECONDARY_LABEL:-}"
if [ -z "${CLOUDROUTE_CONFIG:-}" ] && [ -z "${PUFFROUTE_CONFIG:-}" ] \
  && [ ! -r "$CONFIG_FILE" ] && [ -r "$LEGACY_CONFIG" ]; then
  CONFIG_FILE="$LEGACY_CONFIG"
fi
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
if [ -n "$ENV_CLOUDROUTE_MIXED" ]; then
  CLOUDROUTE_MIXED="$ENV_CLOUDROUTE_MIXED"
fi
if [ -n "$ENV_SECONDARY_MIXED" ]; then CLOUDROUTE_SECONDARY_MIXED="$ENV_SECONDARY_MIXED"; fi
if [ -n "$ENV_SECONDARY_LABEL" ]; then CLOUDROUTE_SECONDARY_LABEL="$ENV_SECONDARY_LABEL"; fi

ROUTE="${1:-}"
EXIT_IP="${2:-}"
DEFAULT_MIXED="${CLOUDROUTE_MIXED:-${PUFFROUTE_MIXED:-127.0.0.1:7890}}"
GOOGLE_MIXED="${CLOUDROUTE_SECONDARY_MIXED:-${CLOUDROUTE_GOOGLE_MIXED:-${PUFFROUTE_GOOGLE_MIXED:-127.0.0.1:7891}}}"
SECONDARY_LABEL="${CLOUDROUTE_SECONDARY_LABEL:-Google / Gemini}"
CHROME="${CLOUDROUTE_CHROME:-${PUFFROUTE_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
DRY_RUN="${CLOUDROUTE_PRIVATE_BROWSER_DRY_RUN:-${PUFFROUTE_PRIVATE_BROWSER_DRY_RUN:-}}"

case "$ROUTE" in
  default)
    PROXY="$DEFAULT_MIXED"
    ROUTE_LABEL="默认出口"
    ;;
  google)
    PROXY="$GOOGLE_MIXED"
    ROUTE_LABEL="$SECONDARY_LABEL 链路"
    ;;
  *)
    echo "用法: $0 {default|google} [出口 IP]" >&2
    exit 2
    ;;
esac

if ! printf '%s' "$PROXY" | /usr/bin/grep -qE '^127\.0\.0\.1:[0-9]{2,5}$'; then
  echo "隔离检测只允许使用本机回环代理，当前配置无效: $PROXY" >&2
  exit 2
fi

if [ ! -x "$CHROME" ]; then
  echo "未找到 Google Chrome；请先安装 Chrome，或设置 CLOUDROUTE_CHROME。" >&2
  exit 1
fi

if ! printf '%s' "$EXIT_IP" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  && [ "$DRY_RUN" != "1" ]; then
  candidate=$(/usr/bin/curl -sS --proxy "http://$PROXY" --max-time 8 \
    https://api.ipify.org 2>/dev/null || true)
  if printf '%s' "$candidate" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    EXIT_IP="$candidate"
  fi
fi

URLS=(
  "https://browserleaks.com/ip"
  "https://iphey.com/"
  "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test"
)

if printf '%s' "$EXIT_IP" | /usr/bin/grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  URLS+=(
    "https://scamalytics.com/ip/$EXIT_IP"
    "https://www.abuseipdb.com/check/$EXIT_IP"
  )
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "route=$ROUTE_LABEL"
  echo "proxy=$PROXY"
  echo "url_count=${#URLS[@]}"
  exit 0
fi

PROFILE_DIR=$(/usr/bin/mktemp -d -t cloudroute-browser)
cleanup() {
  case "$PROFILE_DIR" in
    /private/var/folders/*/T/cloudroute-browser.*|/var/folders/*/T/cloudroute-browser.*|/private/tmp/cloudroute-browser.*)
      /bin/rm -rf -- "$PROFILE_DIR"
      ;;
  esac
}
trap cleanup EXIT INT TERM

echo "已打开 $ROUTE_LABEL 隔离检测；关闭该 Chrome 窗口后会清理临时资料。"

"$CHROME" \
  --user-data-dir="$PROFILE_DIR" \
  --incognito \
  --no-first-run \
  --no-default-browser-check \
  --disable-extensions \
  --disable-sync \
  --disable-background-networking \
  --disable-component-update \
  --disable-session-crashed-bubble \
  --proxy-server="http://$PROXY" \
  --new-window \
  "${URLS[@]}"
