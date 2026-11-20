#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
MAC_SOURCE="$PROJECT_ROOT/Sources/DashboardView.swift"
WINDOWS_SOURCE="$PROJECT_ROOT/Windows/MainWindow.xaml.cs"

for url in \
  'https://ippure.com/' \
  'https://ipcheck.ing/?hl=zh' \
  'https://browserleaks.com/ip' \
  'https://browserleaks.com/webrtc' \
  'https://www.dnsleaktest.com/' \
  'https://test-ipv6.com/' \
  'https://speed.cloudflare.com/'; do
  /usr/bin/grep -Fq "$url" "$MAC_SOURCE"
  /usr/bin/grep -Fq "$url" "$WINDOWS_SOURCE"
done

/usr/bin/grep -Fq 'NSWorkspace.shared.open(url)' "$MAC_SOURCE"
/usr/bin/grep -Fq 'UseShellExecute = true' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'IpPurityButton_Click' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'PrivacyButton_Click' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'SpeedButton_Click' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'browserPrompt = BrowserLaunchPrompt(' "$MAC_SOURCE"
/usr/bin/grep -Fq 'ConfirmBrowserOpen(' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq 'primaryTitle: "继续打开"' "$MAC_SOURCE"
/usr/bin/grep -Fq '"继续打开"' "$WINDOWS_SOURCE"
/usr/bin/grep -Fq '/bin/rm -f "$USER_BIN/proxygauge-private-browser"' "$PROJECT_ROOT/Scripts/install.sh"

if /usr/bin/grep -rnE \
  'proxygauge-private-browser|PrivateBrowserService|AdvancedDetectionWindow|--user-data-dir=|--proxy-server=' \
  "$PROJECT_ROOT/Sources" "$PROJECT_ROOT/Windows" "$PROJECT_ROOT/Scripts/build.sh"; then
  echo "Legacy isolated browser implementation must not be referenced." >&2
  exit 1
fi

echo "ProxyGauge browser tool card tests passed."
