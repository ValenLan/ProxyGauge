#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
MAC_INSTALLER="$PROJECT_ROOT/Scripts/install-release-macos.sh"
MAC_PACKAGER="$PROJECT_ROOT/Scripts/package-macos.sh"
WINDOWS_INSTALLER="$PROJECT_ROOT/Scripts/install-release-windows.ps1"
NPM_INSTALLER="$PROJECT_ROOT/Scripts/proxygauge-npm-lib.mjs"
NPM_WINDOWS_INSTALLER="$PROJECT_ROOT/Scripts/install-release-windows.mjs"
APP_UPDATER="$PROJECT_ROOT/Scripts/proxygauge-updater.sh"
BUILD_WORKFLOW="$PROJECT_ROOT/.github/workflows/build.yml"
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-installer-test.XXXXXX")
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

/bin/bash -n "$MAC_INSTALLER"
/bin/bash -n "$MAC_PACKAGER"
/bin/bash -n "$APP_UPDATER"

PACKAGE_VERSION=$(/usr/bin/env node -e \
  "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).version)" \
  "$PROJECT_ROOT/package.json")
MAC_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$PROJECT_ROOT/Info.plist")
MAC_MINIMUM_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  "$PROJECT_ROOT/Info.plist")
MAC_MINIMUM_MAJOR=${MAC_MINIMUM_VERSION%%.*}
WINDOWS_VERSION=$(/usr/bin/sed -nE \
  's|^[[:space:]]*<Version>([^<]+)</Version>[[:space:]]*$|\1|p' \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj")
WINDOWS_ASSEMBLY_VERSION=$(/usr/bin/sed -nE \
  's|^[[:space:]]*<AssemblyVersion>([^<]+)</AssemblyVersion>[[:space:]]*$|\1|p' \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj")
WINDOWS_FILE_VERSION=$(/usr/bin/sed -nE \
  's|^[[:space:]]*<FileVersion>([^<]+)</FileVersion>[[:space:]]*$|\1|p' \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj")
if ! [[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "package.json must contain a stable three-part release version." >&2
  exit 1
fi
if [ "$PACKAGE_VERSION" != "$MAC_VERSION" ] || [ "$PACKAGE_VERSION" != "$WINDOWS_VERSION" ]; then
  echo "Release versions disagree: npm=$PACKAGE_VERSION macOS=$MAC_VERSION Windows=$WINDOWS_VERSION." >&2
  exit 1
fi
if ! [[ "$MAC_MINIMUM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || \
   ! [[ "$MAC_MINIMUM_MAJOR" =~ ^[0-9]+$ ]]; then
  echo "Info.plist must contain a supported two-part minimum macOS version." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq "MINIMUM_MACOS_MAJOR=$MAC_MINIMUM_MAJOR" "$MAC_INSTALLER"; then
  echo "The macOS installer minimum version must match Info.plist ($MAC_MINIMUM_VERSION)." >&2
  exit 1
fi
SUPPORTED_MACOS_VERSION="$MAC_MINIMUM_MAJOR.0"
UNSUPPORTED_MACOS_VERSION="$((10#$MAC_MINIMUM_MAJOR - 1)).9.9"
PROXYGAUGE_INSTALLER_OS_CHECK_ONLY=1 \
PROXYGAUGE_INSTALLER_TEST_PRODUCT_VERSION="$SUPPORTED_MACOS_VERSION" \
  /bin/bash "$MAC_INSTALLER" > "$TEMP_ROOT/supported-macos.out"
/usr/bin/grep -Fq "macOS $SUPPORTED_MACOS_VERSION 与 ProxyGauge 正式版兼容。" \
  "$TEMP_ROOT/supported-macos.out"
if PROXYGAUGE_INSTALLER_OS_CHECK_ONLY=1 \
   PROXYGAUGE_INSTALLER_TEST_PRODUCT_VERSION="$UNSUPPORTED_MACOS_VERSION" \
   /bin/bash "$MAC_INSTALLER" > "$TEMP_ROOT/unsupported-macos.out" 2>&1; then
  echo "The macOS installer must reject an unsupported OS before downloading." >&2
  exit 1
fi
/usr/bin/grep -Fq "需要 macOS $MAC_MINIMUM_MAJOR 或更高版本" \
  "$TEMP_ROOT/unsupported-macos.out"
if PROXYGAUGE_INSTALLER_OS_CHECK_ONLY=1 \
   PROXYGAUGE_INSTALLER_TEST_PRODUCT_VERSION='26.beta' \
   /bin/bash "$MAC_INSTALLER" > "$TEMP_ROOT/malformed-macos.out" 2>&1; then
  echo "The macOS installer must reject a malformed operating-system version." >&2
  exit 1
fi
/usr/bin/grep -Fq '无法识别当前 macOS 版本' "$TEMP_ROOT/malformed-macos.out"
if PROXYGAUGE_INSTALLER_TEST_PRODUCT_VERSION="$SUPPORTED_MACOS_VERSION" \
   /bin/bash "$MAC_INSTALLER" > "$TEMP_ROOT/forged-macos-install.out" 2>&1; then
  echo "The injected macOS version must never enter a real installation." >&2
  exit 1
fi
/usr/bin/grep -Fq '只能用于非管理员兼容性检查' "$TEMP_ROOT/forged-macos-install.out"

# Extract only the side-effect-free function definitions, never source the installer.
/usr/bin/awk '
  /^# END_PROXYGAUGE_RUNNING_INSTANCE_CHECK$/ { capture = 0 }
  capture { print }
  /^# BEGIN_PROXYGAUGE_RUNNING_INSTANCE_CHECK$/ { capture = 1 }
' "$MAC_INSTALLER" > "$TEMP_ROOT/running-instance-check.sh"
/bin/bash -n "$TEMP_ROOT/running-instance-check.sh"
source "$TEMP_ROOT/running-instance-check.sh"
PROCESS_FIXTURE="$TEMP_ROOT/process fixtures"
PROCESS_APP="$PROCESS_FIXTURE/Renamed ProxyGauge.app"
OTHER_APP="$PROCESS_FIXTURE/Other.app"
MISSING_ID_APP="$PROCESS_FIXTURE/MissingID.app"
LITERAL_APP="$PROCESS_FIXTURE/"'Literal $(false).app'
/bin/mkdir -p "$PROCESS_APP/Contents" "$OTHER_APP/Contents" \
  "$MISSING_ID_APP/Contents" "$LITERAL_APP/Contents"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.valenlan.proxygauge' \
  "$PROCESS_APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string example.other' \
  "$OTHER_APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MissingID' \
  "$MISSING_ID_APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.valenlan.proxygauge' \
  "$LITERAL_APP/Contents/Info.plist" >/dev/null
PROCESS_TABLE="  501  4101 $PROCESS_APP/Contents/MacOS/ProxyGauge
  502  4102 $PROCESS_APP/Contents/MacOS/ProxyGauge
  501  4103 $OTHER_APP/Contents/MacOS/ProxyGauge
  501  4104 $PROCESS_APP/Contents/MacOS/ProxyGaugeHelper
  501  4105 /usr/local/bin/ProxyGauge
  501  4106 /bin/bash $PROCESS_APP/Contents/MacOS/ProxyGauge
  501  4107 $MISSING_ID_APP/Contents/MacOS/ProxyGauge
  501  4108 $PROCESS_FIXTURE/DoesNotExist.app/Contents/MacOS/ProxyGauge
  501  4109 $LITERAL_APP/Contents/MacOS/ProxyGauge
  501     0 $PROCESS_APP/Contents/MacOS/ProxyGauge
  bad  4110 $PROCESS_APP/Contents/MacOS/ProxyGauge
  501   bad $PROCESS_APP/Contents/MacOS/ProxyGauge
  malformed row"
MATCHED_PIDS=$(proxygauge_running_pids_from_process_table "$PROCESS_TABLE" 501)
if [ "$MATCHED_PIDS" != $'4101\n4109' ]; then
  echo "Process detection must match only the selected user's exact ProxyGauge bundle instances." >&2
  exit 1
fi
if [ "$(proxygauge_running_pids_from_process_table "$PROCESS_TABLE" 502)" != 4102 ] || \
   [ -n "$(proxygauge_running_pids_from_process_table "$PROCESS_TABLE" 503)" ] || \
   [ -n "$(proxygauge_running_pids_from_process_table '' 501)" ]; then
  echo "Process detection must isolate users and accept an empty process table." >&2
  exit 1
fi
if proxygauge_running_pids_from_process_table "$PROCESS_TABLE" not-a-uid; then
  echo "Process detection must reject an invalid installation user." >&2
  exit 1
fi

# Check every real install boundary without running ps, downloading, or asking for elevation.
/usr/bin/awk '
  /^proxygauge_assert_no_running_instances "\$INSTALLING_USER_ID"$/ { checks++ }
  /^TEMP_DIR=/ && checks != 1 { exit 1 }
  /^if ! \/usr\/bin\/env -i/ && checks != 2 { exit 1 }
  END { if (checks != 2) exit 1 }
' "$MAC_INSTALLER"
if [ "$(/usr/bin/grep -Fc 'proxygauge_assert_no_running_instances "$installing_user_id"' "$MAC_INSTALLER")" -ne 2 ]; then
  echo "The elevated installer must recheck running instances before staging and replacing the app." >&2
  exit 1
fi
/usr/bin/grep -Fq 'builtin declare -f proxygauge_running_pids_from_process_table' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'builtin declare -f proxygauge_assert_no_running_instances' "$MAC_INSTALLER"

EXPECTED_WINDOWS_BINARY_VERSION="$PACKAGE_VERSION.0"
if [ "$WINDOWS_ASSEMBLY_VERSION" != "$EXPECTED_WINDOWS_BINARY_VERSION" ] || \
   [ "$WINDOWS_FILE_VERSION" != "$EXPECTED_WINDOWS_BINARY_VERSION" ]; then
  echo "Windows assembly/file versions must both be $EXPECTED_WINDOWS_BINARY_VERSION." >&2
  exit 1
fi

/usr/bin/awk '
  /^# END_PROXYGAUGE_RUNNING_INSTANCE_CHECK$/ { capture = 0 }
  /^ROOT_INSTALL$/ { capture = 0 }
  capture { print }
  /^# BEGIN_PROXYGAUGE_RUNNING_INSTANCE_CHECK$/ { capture = 1 }
  /ROOT_INSTALL_SCRIPT <<.*ROOT_INSTALL/ { capture = 1 }
' "$MAC_INSTALLER" > "$TEMP_ROOT/root-install.sh"
/bin/bash -n "$TEMP_ROOT/root-install.sh"
/usr/bin/awk '
  /^ADMIN_APPLESCRIPT_BODY$/ { capture = 0 }
  capture { print }
  /ADMIN_APPLESCRIPT <<.*ADMIN_APPLESCRIPT_BODY/ { capture = 1 }
' "$MAC_INSTALLER" > "$TEMP_ROOT/admin-installer.applescript"
/usr/bin/osacompile -o "$TEMP_ROOT/admin-installer.scpt" "$TEMP_ROOT/admin-installer.applescript"

/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'SHA256SUMS.txt' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/shasum -a 256' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'PROXYGAUGE_VERSION' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'PACKAGE_STAGE=$(/usr/bin/mktemp -d "$ARCHIVE_DIR/.proxygauge-package.XXXXXX")' \
  "$MAC_PACKAGER"
/usr/bin/grep -Fq '/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED_ARCHIVE"' \
  "$MAC_PACKAGER"
/usr/bin/grep -Fq -- "-c 'Print :CFBundleIdentifier'" "$MAC_PACKAGER"
/usr/bin/grep -Fq -- "-c 'Print :CFBundleShortVersionString'" "$MAC_PACKAGER"
/usr/bin/grep -Fq '/usr/bin/lipo -archs' "$MAC_PACKAGER"
/usr/bin/grep -Fq 'if [ "$architectures" != "arm64" ]; then' "$MAC_PACKAGER"
/usr/bin/grep -Fq '/bin/mv -f "$STAGED_ARCHIVE" "$ARCHIVE"' "$MAC_PACKAGER"
if /usr/bin/grep -Fq '/bin/rm -f "$ARCHIVE"' "$MAC_PACKAGER"; then
  echo "macOS packaging failures must preserve the previous verified archive." >&2
  exit 1
fi
/usr/bin/grep -Fq "install_dir='/Library/Application Support/ProxyGauge'" "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.install.lock' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/bin/bash -p -c' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/bin/install -o root -g wheel -m 600 "$archive_source" "$staged_archive"' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/usr/sbin/chown -R root:wheel "$staged_app"' "$MAC_INSTALLER"
/usr/bin/grep -Fq '/bin/ln -s "$destination" "$application_link"' "$MAC_INSTALLER"
/usr/bin/grep -Fq -- '--connect-timeout 15' "$MAC_INSTALLER"
/usr/bin/grep -Fq -- '--max-time 300' "$MAC_INSTALLER"
/usr/bin/grep -Fq -- "--proto-redir '=https'" "$MAC_INSTALLER"
/usr/bin/grep -Fq -- '--max-filesize "$maximum_bytes"' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'if (count == 1) print found' "$MAC_INSTALLER"
/usr/bin/grep -Fq '[ "$LATEST_URL" != "https://github.com/$REPOSITORY/releases/tag/$TAG" ]' "$MAC_INSTALLER"
if [ "$(/usr/bin/grep -Fc '/usr/bin/curl -q \' "$MAC_INSTALLER")" -ne 2 ]; then
  echo "Every macOS release download must ignore user curl configuration." >&2
  exit 1
fi
/usr/bin/grep -Fq 'if [ "$committed" -ne 1 ]; then' "$MAC_INSTALLER"
/usr/bin/grep -Fq 'preserve_install_stage=1' "$MAC_INSTALLER"
/usr/bin/grep -Fq '可恢复副本保留在受保护目录' "$MAC_INSTALLER"
if /usr/bin/grep -Fq 'INSTALL_DIR="$HOME/Applications"' "$MAC_INSTALLER"; then
  echo "The privileged macOS app must not be installed in a user-writable bundle path." >&2
  exit 1
fi
/usr/bin/grep -Fq 'ValenLan/ProxyGauge' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'releases/latest' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '[Security.Cryptography.SHA256]::Create()' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '[Environment]::SystemDirectory' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '[Environment+SpecialFolder]::ProgramFiles' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'msiexec.exe' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '$StartInfo.Verb = "RunAs"' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'PROXYGAUGE_VERSION' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '$ProxyCandidate.AbsolutePath -ne "/"' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '$ProxyText.ToLowerInvariant() -in @("false", "null")' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq '$Installer.WaitForExit(1800000)' "$WINDOWS_INSTALLER"
/usr/bin/grep -Fq 'Remove-KnownInstallerTempDirectory $TempDirectory' "$WINDOWS_INSTALLER"
if /usr/bin/grep -Fq '[IO.Directory]::Delete($TempDirectory, $true)' "$WINDOWS_INSTALLER" || \
   /usr/bin/grep -Fq '[IO.Directory]::Delete($SecureDirectory, $true)' "$WINDOWS_INSTALLER"; then
  echo "The Windows installer must not recursively delete mutable or elevated staging paths." >&2
  exit 1
fi
/usr/bin/grep -Fq '"ProxyGauge-$VERSION-macOS-arm64.zip"' "$BUILD_WORKFLOW"
/usr/bin/grep -Fq '"ProxyGauge-$VERSION-win-x64.msi"' "$BUILD_WORKFLOW"
/usr/bin/grep -Fq '"ProxyGauge-$VERSION-win-arm64.msi"' "$BUILD_WORKFLOW"
if /usr/bin/grep -Fq 'release-assets/ProxyGauge-*.zip' "$BUILD_WORKFLOW" || \
   /usr/bin/grep -Fq 'release-assets/ProxyGauge-*.msi' "$BUILD_WORKFLOW"; then
  echo "The release job must publish only the three exact versioned package names." >&2
  exit 1
fi
/usr/bin/grep -Fq 'Version="$(ProductVersion)"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq '/usr/bin/shasum -a 256' "$APP_UPDATER"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$APP_UPDATER"
/usr/bin/grep -Fq 'CFBundleIdentifier' "$APP_UPDATER"
/usr/bin/grep -Fq 'ProxyGauge.previous.app' "$APP_UPDATER"
/usr/bin/grep -Fq 'SHA256.HashDataAsync' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'msiexec.exe' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'var hasher = SHA256()' "$PROJECT_ROOT/Sources/UpdateService.swift"
/usr/bin/grep -Fq 'releases/latest' "$PROJECT_ROOT/Sources/UpdateService.swift"
/usr/bin/grep -Fq 'staged_updater' "$PROJECT_ROOT/Sources/UpdateService.swift"
/usr/bin/grep -Fq 'staged_archive' "$PROJECT_ROOT/Sources/UpdateService.swift"
/usr/bin/grep -Fq 'LOG_DIR=/var/log/ProxyGauge' "$APP_UPDATER"
if /usr/bin/grep -Fq 'PROXYGAUGE_UPDATE_LOG_HOME' "$APP_UPDATER"; then
  echo "The privileged updater must not write through a user-selected log path." >&2
  exit 1
fi

if /usr/bin/grep -Eiq \
  'xattr.+(quarantine|com\.apple\.quarantine)|spctl.+disable|Set-MpPreference|ExecutionPolicy.+Bypass' \
  "$MAC_INSTALLER" "$WINDOWS_INSTALLER" "$NPM_INSTALLER" "$NPM_WINDOWS_INSTALLER"; then
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
