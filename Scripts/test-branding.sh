#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

for required_path in \
  "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift" \
  "$PROJECT_ROOT/Resources/ProxyGauge.icns" \
  "$PROJECT_ROOT/Resources/ProxyGauge.png" \
  "$PROJECT_ROOT/Resources/ProxyGauge-source.png" \
  "$PROJECT_ROOT/Helpers/ProxyGauge Admin.applescript" \
  "$PROJECT_ROOT/PF/proxygauge.conf.template" \
  "$PROJECT_ROOT/Rules/ProxyGauge-Merge.yaml" \
  "$PROJECT_ROOT/Rules/ProxyGauge-Google-Chain-Probe.yaml" \
  "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-check.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-ip-risk.jxa" \
  "$PROJECT_ROOT/Scripts/proxygauge-chain-check.jxa" \
  "$PROJECT_ROOT/Scripts/proxygauge-killswitch" \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj" \
  "$PROJECT_ROOT/Windows/Assets/ProxyGauge.ico" \
  "$PROJECT_ROOT/Windows/Assets/ProxyGauge.png"; do
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
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_ROOT/Info.plist")" = "26.0" ]

/usr/bin/grep -Fq 'struct ProxyGaugeApp: App' "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
/usr/bin/grep -Fq -- '-target arm64-apple-macosx26.0' "$PROJECT_ROOT/Scripts/build.sh"
/usr/bin/grep -Fq '<RootNamespace>ProxyGauge</RootNamespace>' "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj"
/usr/bin/grep -Fq '<Resource Include="Assets\ProxyGauge.png" />' "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj"
/usr/bin/grep -Fq 'const sizes = [16, 24, 32, 48, 64, 128, 256];' "$PROJECT_ROOT/Scripts/generate-icons.mjs"
/usr/bin/grep -Fq 'NSBezierPath(roundedRect: tile, xRadius: 176, yRadius: 176)' "$PROJECT_ROOT/Scripts/apply-icon-mask.swift"

if /usr/bin/grep -Eiq \
  'cloudcheck|cloudlink|cloudroute|puffroute' \
  "$PROJECT_ROOT/Scripts/proxygauge-check.sh" \
  "$PROJECT_ROOT/Scripts/proxygauge-backend.sh" \
  "$PROJECT_ROOT/Scripts/install.sh" \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs" \
  "$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"; then
  echo 'Current app and config paths must not contain legacy product compatibility.' >&2
  exit 1
fi

if /usr/bin/grep -Eiq \
  'cloudcheck|cloudlink|cloudroute|puffroute|\.NET 8|single-file|单文件' \
  "$PROJECT_ROOT/README.md" \
  "$PROJECT_ROOT/Windows/README.md" \
  "$PROJECT_ROOT/config.example"; then
  echo 'Current documentation must describe only the latest ProxyGauge platform contract.' >&2
  exit 1
fi

echo "ProxyGauge source branding tests passed."
