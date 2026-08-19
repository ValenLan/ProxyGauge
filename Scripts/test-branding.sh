#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)

[ "$(/usr/bin/basename "$PROJECT_ROOT")" = "CloudCheck" ]

for required_path in \
  "$PROJECT_ROOT/Sources/CloudCheckApp.swift" \
  "$PROJECT_ROOT/Resources/CloudCheck.icns" \
  "$PROJECT_ROOT/Resources/CloudCheck.png" \
  "$PROJECT_ROOT/Helpers/CloudCheck Admin.applescript" \
  "$PROJECT_ROOT/PF/cloudcheck.conf.template" \
  "$PROJECT_ROOT/Rules/CloudCheck-Merge.yaml" \
  "$PROJECT_ROOT/Rules/CloudCheck-Google-Chain-Probe.yaml" \
  "$PROJECT_ROOT/Scripts/cloudcheck-backend.sh" \
  "$PROJECT_ROOT/Scripts/cloudcheck-check.sh" \
  "$PROJECT_ROOT/Scripts/cloudcheck-killswitch" \
  "$PROJECT_ROOT/Windows/CloudCheck.Windows.csproj" \
  "$PROJECT_ROOT/Windows/Assets/CloudCheck.ico"; do
  [ -e "$required_path" ]
done

if /usr/bin/find "$PROJECT_ROOT" \
  -path "$PROJECT_ROOT/.git" -prune -o \
  -path "$PROJECT_ROOT/build" -prune -o \
  -path "$PROJECT_ROOT/dist" -prune -o \
  \( -iname '*CloudLinkGuard*' -o -iname '*CloudRoute*' -o -iname '*PuffRoute*' \) \
  -print | /usr/bin/grep -q .; then
  echo "Current source paths must use the CloudCheck name." >&2
  exit 1
fi

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PROJECT_ROOT/Info.plist")" = "CloudCheck" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PROJECT_ROOT/Info.plist")" = "CloudCheck.icns" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_ROOT/Info.plist")" = "com.valenlan.cloudcheck" ]

/usr/bin/grep -Fq 'struct CloudCheckApp: App' "$PROJECT_ROOT/Sources/CloudCheckApp.swift"
/usr/bin/grep -Fq '<RootNamespace>CloudCheck</RootNamespace>' "$PROJECT_ROOT/Windows/CloudCheck.Windows.csproj"
/usr/bin/grep -Fq 'CLOUDLINK_GUARD_CONFIG_PATH=' "$PROJECT_ROOT/Scripts/cloudcheck-check.sh"
/usr/bin/grep -Fq 'Path.Combine(appData, "CloudLinkGuard", "config.json")' \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs"

echo "CloudCheck source branding and migration compatibility tests passed."
