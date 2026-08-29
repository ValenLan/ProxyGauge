#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
MAC_INSTALLER="$PROJECT_ROOT/Scripts/install-release-macos.sh"
WINDOWS_INSTALLER="$PROJECT_ROOT/Scripts/install-release-windows.ps1"

/bin/bash -n "$MAC_INSTALLER"

/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'SHA256SUMS.txt' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/shasum -a 256' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'releases/latest' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'Get-FileHash -Algorithm SHA256' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'msiexec.exe' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq -- '-Verb RunAs' "$WINDOWS_INSTALLER"

if /usr/bin/grep -Eiq \
  'xattr.+(quarantine|com\.apple\.quarantine)|spctl.+disable|Set-MpPreference|ExecutionPolicy.+Bypass' \
  "$MAC_INSTALLER" "$WINDOWS_INSTALLER"; then
  echo "Release installers must not bypass platform security controls." >&2
  exit 1
fi

/usr/bin/grep -Fq 'MIT License' "$PROJECT_ROOT/LICENSE"
/usr/bin/grep -Fq 'THE SOFTWARE IS PROVIDED "AS IS"' "$PROJECT_ROOT/LICENSE"
/usr/bin/grep -Fq 'install-release-macos.sh' "$PROJECT_ROOT/README.md"
/usr/bin/grep -Fq 'install-release-windows.ps1' "$PROJECT_ROOT/README.md"

echo "ProxyGauge release installer tests passed."
