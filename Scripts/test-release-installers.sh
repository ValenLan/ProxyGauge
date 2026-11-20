#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
MAC_INSTALLER="$PROJECT_ROOT/Scripts/install-release-macos.sh"
WINDOWS_INSTALLER="$PROJECT_ROOT/Scripts/install-release-windows.ps1"
NPM_INSTALLER="$PROJECT_ROOT/Scripts/proxygauge-npm-lib.mjs"
APP_UPDATER="$PROJECT_ROOT/Scripts/proxygauge-updater.sh"

/bin/bash -n "$MAC_INSTALLER"
/bin/bash -n "$APP_UPDATER"

/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'SHA256SUMS.txt' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/shasum -a 256' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'PROXYGAUGE_VERSION' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'releases/latest' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'Get-FileHash -Algorithm SHA256' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'msiexec.exe' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq -- '-Verb RunAs' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'PROXYGAUGE_VERSION' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/shasum -a 256' "$APP_UPDATER"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$APP_UPDATER"
/usr/bin/grep -Fq 'CFBundleIdentifier' "$APP_UPDATER"
/usr/bin/grep -Fq 'ProxyGauge.previous.app' "$APP_UPDATER"
/usr/bin/grep -Fq 'SHA256.HashDataAsync' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'msiexec.exe' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'SHA256.hash' "$PROJECT_ROOT/Sources/UpdateService.swift"
/usr/bin/grep -Fq 'releases/latest' "$PROJECT_ROOT/Sources/UpdateService.swift"

if /usr/bin/grep -Eiq \
  'xattr.+(quarantine|com\.apple\.quarantine)|spctl.+disable|Set-MpPreference|ExecutionPolicy.+Bypass' \
  "$MAC_INSTALLER" "$WINDOWS_INSTALLER" "$NPM_INSTALLER"; then
  echo "Release installers must not bypass platform security controls." >&2
  exit 1
fi

/usr/bin/grep -Fq 'MIT License' "$PROJECT_ROOT/LICENSE"
/usr/bin/grep -Fq 'THE SOFTWARE IS PROVIDED "AS IS"' "$PROJECT_ROOT/LICENSE"
/usr/bin/grep -Fq 'install-release-macos.sh' "$PROJECT_ROOT/README.md"
/usr/bin/grep -Fq 'install-release-windows.ps1' "$PROJECT_ROOT/README.md"
/usr/bin/grep -Fq 'npm install -g proxygauge' "$PROJECT_ROOT/README.md"

/usr/bin/env node --test "$PROJECT_ROOT/Tests/npm-installer.test.mjs"

echo "ProxyGauge release installer tests passed."
