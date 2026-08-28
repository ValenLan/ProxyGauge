#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
MAC_SOURCE="$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
WINDOWS_SOURCE="$PROJECT_ROOT/Windows/MainWindow.xaml.cs"

for url in \
  'https://ippure.com/' \
  'https://ipcheck.ing/?hl=zh' \
  'https://browserleaks.com/ip' \
  'https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test' \
  'https://scamalytics.com/ip' \
  'https://www.abuseipdb.com/check/'; do
  /usr/bin/grep -Fq "$url" "$MAC_SOURCE"
  /usr/bin/grep -Fq "$url" "$WINDOWS_SOURCE"
done

/usr/bin/grep -Fq '.alert("打开浏览器人工复核？"' "$MAC_SOURCE"
/usr/bin/grep -Fq 'Button("打开 6 个网站")' "$MAC_SOURCE"
/usr/bin/grep -Fq '部分网站可能要求人机验证' "$MAC_SOURCE"
/usr/bin/grep -Fq '各站结果不会计入链路分' "$MAC_SOURCE"
/usr/bin/grep -Fq 'let exitIP = await model.resolveDefaultExitIP()' "$MAC_SOURCE"
/usr/bin/grep -Fq 'https://scamalytics.com/ip/\(exitIP)' "$MAC_SOURCE"
/usr/bin/grep -Fq 'https://www.abuseipdb.com/check/\(exitIP)' "$MAC_SOURCE"
/usr/bin/grep -Fq 'NSWorkspace.shared.open(url)' "$MAC_SOURCE"
/usr/bin/grep -Fq '"打开浏览器人工复核？"' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'MessageBoxButton.YesNo' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'UseShellExecute = true' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'ResolveDefaultExitIpAsync' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'https://scamalytics.com/ip/{escapedIp}' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'https://www.abuseipdb.com/check/{escapedIp}' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq '/bin/rm -f "$USER_BIN/proxygauge-private-browser"' "$PROJECT_ROOT/Scripts/install.sh"

if rg -n \
  'proxygauge-private-browser|PrivateBrowserService|AdvancedDetectionWindow|--user-data-dir=|--proxy-server=' \
  "$PROJECT_ROOT/Sources" "$PROJECT_ROOT/Windows" "$PROJECT_ROOT/Scripts/build.sh"; then
  echo "Legacy isolated browser implementation must not be referenced." >&2
  exit 1
fi

echo "ProxyGauge manual browser review tests passed."
