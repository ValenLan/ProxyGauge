#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

for required_path in \
  "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift" \
  "$PROJECT_ROOT/Resources/ProxyGauge.icns" \
  "$PROJECT_ROOT/Resources/ProxyGauge.png" \
  "$PROJECT_ROOT/Helpers/ProxyGauge Admin.applescript" \
  "$PROJECT_ROOT/PF/proxygauge.conf.template" \
  "$PROJECT_ROOT/Rules/ProxyGauge-Merge.yaml" \
  "$PROJECT_ROOT/Rules/ProxyGauge-Google-Chain-Probe.yaml" \
  "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-check.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" \
  "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" \
  "$PROJECT_ROOT/Scripts/proxygauge-private-browser.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-killswitch" \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj" \
  "$PROJECT_ROOT/Windows/Assets/ProxyGauge.ico"; do
  [ -e "$required_path" ]
done

if /usr/bin/find "$PROJECT_ROOT" -mindepth 1 \
  -path "$PROJECT_ROOT/.git" -prune -o \
  -path "$PROJECT_ROOT/build" -prune -o \
  -path "$PROJECT_ROOT/dist" -prune -o \
  -path "$PROJECT_ROOT/docs/handoffs" -prune -o \
  -type d \( -name bin -o -name obj \) -prune -o \
  \( -iname '*CloudCheck*' -o -iname '*CloudLinkGuard*' -o -iname '*CloudRoute*' -o -iname '*PuffRoute*' \) \
  -print | /usr/bin/grep -q .; then
  echo "Current source paths must use the ProxyGauge name." >&2
  exit 1
fi

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PROJECT_ROOT/Info.plist")" = "ProxyGauge" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PROJECT_ROOT/Info.plist")" = "ProxyGauge.icns" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_ROOT/Info.plist")" = "com.valenlan.proxygauge" ]

/usr/bin/grep -Fq 'struct ProxyGaugeApp: App' "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
/usr/bin/grep -Fq '<RootNamespace>ProxyGauge</RootNamespace>' "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj"
/usr/bin/grep -Fq 'CLOUDCHECK_CONFIG_PATH=' "$PROJECT_ROOT/Scripts/proxygauge-check.sh"
/usr/bin/grep -Fq 'CLOUDLINK_GUARD_CONFIG_PATH=' "$PROJECT_ROOT/Scripts/proxygauge-check.sh"
/usr/bin/grep -Fq 'Path.Combine(appData, "CloudCheck", "config.json")' \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs"
/usr/bin/grep -Fq 'Path.Combine(appData, "CloudLinkGuard", "config.json")' \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs"

echo "ProxyGauge source branding and migration compatibility tests passed."
