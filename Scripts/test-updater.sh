#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-updater-test.XXXXXX")
/bin/mkdir -p "$TEMP_ROOT/module-cache"
WAIT_APP_PID=
WAIT_UPDATER_PID=
cleanup() {
  if [ -n "$WAIT_UPDATER_PID" ]; then
    /bin/kill "$WAIT_UPDATER_PID" 2>/dev/null || true
  fi
  if [ -n "$WAIT_APP_PID" ]; then
    /bin/kill "$WAIT_APP_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

/bin/bash -n "$PROJECT_ROOT/Scripts/proxygauge-updater.sh"

if "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" >/dev/null 2>&1; then
  echo 'Updater must reject incomplete arguments.' >&2
  exit 1
fi

make_signed_app() {
  local app_path version marker
  app_path="$1"
  version="$2"
  marker="$3"
  /bin/mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
  /usr/bin/printf '%s\n' '#!/bin/bash' 'exit 0' > "$app_path/Contents/MacOS/ProxyGauge"
  /bin/chmod 755 "$app_path/Contents/MacOS/ProxyGauge"
  /usr/bin/printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.valenlan.proxygauge</string>' \
    "<key>CFBundleShortVersionString</key><string>$version</string>" \
    '<key>CFBundleExecutable</key><string>ProxyGauge</string>' \
    '</dict></plist>' > "$app_path/Contents/Info.plist"
  /usr/bin/printf '%s\n' "$marker" > "$app_path/Contents/Resources/$marker"
  /usr/bin/codesign --force --deep --sign - "$app_path" >/dev/null 2>&1
}

READY_NONCE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
make_ready_handshake() {
  local ready_dir
  ready_dir="$1"
  /bin/mkdir -m 700 "$ready_dir"
  /usr/bin/printf '%s\n' "$ready_dir/ready"
}

HANDSHAKE_FIXTURE="$TEMP_ROOT/update-ready-handshake"
HANDSHAKE_PARENT="$HANDSHAKE_FIXTURE/installed"
HANDSHAKE_DESTINATION="$HANDSHAKE_PARENT/ProxyGauge.app"
HANDSHAKE_NEW_APP="$HANDSHAKE_FIXTURE/new/ProxyGauge.app"
/bin/mkdir -p "$HANDSHAKE_PARENT" "$HANDSHAKE_FIXTURE/new"
make_signed_app "$HANDSHAKE_DESTINATION" 1.6.2 old-version
make_signed_app "$HANDSHAKE_NEW_APP" 1.6.3 new-version
HANDSHAKE_ARCHIVE="$HANDSHAKE_FIXTURE/update.zip"
/usr/bin/ditto -c -k --keepParent "$HANDSHAKE_NEW_APP" "$HANDSHAKE_ARCHIVE"
HANDSHAKE_SHA=$(/usr/bin/shasum -a 256 "$HANDSHAKE_ARCHIVE" | /usr/bin/awk '{ print $1 }')
HANDSHAKE_READY=$(make_ready_handshake "$HANDSHAKE_FIXTURE/ready")
/bin/sleep 30 &
WAIT_APP_PID=$!
PROXYGAUGE_UPDATER_TEST_MODE=1 "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" \
  "$HANDSHAKE_ARCHIVE" "$HANDSHAKE_SHA" 1.6.3 "$HANDSHAKE_DESTINATION" \
  "$WAIT_APP_PID" "$(/usr/bin/id -u)" "$HANDSHAKE_READY" "$READY_NONCE" &
WAIT_UPDATER_PID=$!
for _ in $(/usr/bin/seq 1 200); do
  if [ -f "$HANDSHAKE_READY" ]; then
    break
  fi
  if ! /bin/kill -0 "$WAIT_UPDATER_PID" 2>/dev/null; then
    echo 'Updater exited before publishing its ready marker.' >&2
    wait "$WAIT_UPDATER_PID" || true
    exit 1
  fi
  /bin/sleep 0.05
done
[ "$(/bin/cat "$HANDSHAKE_READY")" = "$READY_NONCE" ]
[ -f "$HANDSHAKE_DESTINATION/Contents/Resources/old-version" ]
[ ! -e "$HANDSHAKE_DESTINATION/Contents/Resources/new-version" ]
/bin/kill "$WAIT_APP_PID"
wait "$WAIT_APP_PID" 2>/dev/null || true
WAIT_APP_PID=
wait "$WAIT_UPDATER_PID"
WAIT_UPDATER_PID=
[ -f "$HANDSHAKE_DESTINATION/Contents/Resources/new-version" ]
[ ! -e "$HANDSHAKE_DESTINATION/Contents/Resources/old-version" ]
[ ! -e "$HANDSHAKE_ARCHIVE" ]
[ ! -e "$HANDSHAKE_READY" ]

PREP_FAIL_APP="$HANDSHAKE_FIXTURE/preparation-failure/ProxyGauge.app"
PREP_FAIL_NEW="$HANDSHAKE_FIXTURE/preparation-failure-new/ProxyGauge.app"
/bin/mkdir -p "$HANDSHAKE_FIXTURE/preparation-failure" "$HANDSHAKE_FIXTURE/preparation-failure-new"
make_signed_app "$PREP_FAIL_APP" 1.6.2 old-version
make_signed_app "$PREP_FAIL_NEW" 1.6.3 new-version
PREP_FAIL_ARCHIVE="$HANDSHAKE_FIXTURE/preparation-failure.zip"
/usr/bin/ditto -c -k --keepParent "$PREP_FAIL_NEW" "$PREP_FAIL_ARCHIVE"
PREP_FAIL_READY=$(make_ready_handshake "$HANDSHAKE_FIXTURE/preparation-failure-ready")
/bin/sleep 30 &
WAIT_APP_PID=$!
if PROXYGAUGE_UPDATER_TEST_MODE=1 "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" \
  "$PREP_FAIL_ARCHIVE" "$(/usr/bin/printf '0%.0s' {1..64})" 1.6.3 "$PREP_FAIL_APP" \
  "$WAIT_APP_PID" "$(/usr/bin/id -u)" "$PREP_FAIL_READY" "$READY_NONCE"; then
  echo 'Updater must reject a bad archive before publishing its ready marker.' >&2
  exit 1
fi
/bin/kill -0 "$WAIT_APP_PID"
[ ! -e "$PREP_FAIL_READY" ]
[ -f "$PREP_FAIL_APP/Contents/Resources/old-version" ]
[ ! -e "$PREP_FAIL_APP/Contents/Resources/new-version" ]
/bin/kill "$WAIT_APP_PID"
wait "$WAIT_APP_PID" 2>/dev/null || true
WAIT_APP_PID=

UPDATER_FIXTURE="$TEMP_ROOT/update-transaction"
DESTINATION_PARENT="$UPDATER_FIXTURE/installed"
DESTINATION="$DESTINATION_PARENT/ProxyGauge.app"
NEW_APP="$UPDATER_FIXTURE/new/ProxyGauge.app"
/bin/mkdir -p "$DESTINATION_PARENT" "$UPDATER_FIXTURE/new"
make_signed_app "$DESTINATION" 1.6.2 old-version
make_signed_app "$NEW_APP" 1.6.3 new-version

FAIL_ARCHIVE="$UPDATER_FIXTURE/fail.zip"
/usr/bin/ditto -c -k --keepParent "$NEW_APP" "$FAIL_ARCHIVE"
FAIL_SHA=$(/usr/bin/shasum -a 256 "$FAIL_ARCHIVE" | /usr/bin/awk '{ print $1 }')
FAIL_READY=$(make_ready_handshake "$UPDATER_FIXTURE/fail-ready")
if PROXYGAUGE_UPDATER_TEST_MODE=1 PROXYGAUGE_UPDATER_TEST_FAIL_FINAL_VERIFY=1 \
  "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" \
  "$FAIL_ARCHIVE" "$FAIL_SHA" 1.6.3 "$DESTINATION" 2147483647 "$(/usr/bin/id -u)" \
  "$FAIL_READY" "$READY_NONCE"; then
  echo 'Injected final verification failure must fail the update.' >&2
  exit 1
fi
[ -f "$DESTINATION/Contents/Resources/old-version" ]
[ ! -e "$DESTINATION/Contents/Resources/new-version" ]
[ -f "$FAIL_ARCHIVE" ]

ROLLBACK_FIXTURE="$TEMP_ROOT/update-rollback-failure"
ROLLBACK_PARENT="$ROLLBACK_FIXTURE/installed"
ROLLBACK_DESTINATION="$ROLLBACK_PARENT/ProxyGauge.app"
ROLLBACK_NEW_APP="$ROLLBACK_FIXTURE/new/ProxyGauge.app"
/bin/mkdir -p "$ROLLBACK_PARENT" "$ROLLBACK_FIXTURE/new"
make_signed_app "$ROLLBACK_DESTINATION" 1.6.2 old-version
make_signed_app "$ROLLBACK_NEW_APP" 1.6.3 new-version
ROLLBACK_ARCHIVE="$ROLLBACK_FIXTURE/fail-rollback.zip"
/usr/bin/ditto -c -k --keepParent "$ROLLBACK_NEW_APP" "$ROLLBACK_ARCHIVE"
ROLLBACK_SHA=$(/usr/bin/shasum -a 256 "$ROLLBACK_ARCHIVE" | /usr/bin/awk '{ print $1 }')
ROLLBACK_READY=$(make_ready_handshake "$ROLLBACK_FIXTURE/fail-ready")
if PROXYGAUGE_UPDATER_TEST_MODE=1 \
  PROXYGAUGE_UPDATER_TEST_FAIL_FINAL_VERIFY=1 \
  PROXYGAUGE_UPDATER_TEST_FAIL_ROLLBACK_MOVE=1 \
  "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" \
  "$ROLLBACK_ARCHIVE" "$ROLLBACK_SHA" 1.6.3 "$ROLLBACK_DESTINATION" \
  2147483647 "$(/usr/bin/id -u)" "$ROLLBACK_READY" "$READY_NONCE"; then
  echo 'Injected rollback failure must fail the update.' >&2
  exit 1
fi
RECOVERY_STAGE=$(/usr/bin/find "$ROLLBACK_PARENT" -maxdepth 1 -type d \
  -name '.proxygauge-update.*' -print -quit)
[ -n "$RECOVERY_STAGE" ]
[ -f "$RECOVERY_STAGE/ProxyGauge.previous.app/Contents/Resources/old-version" ]
[ ! -e "$ROLLBACK_DESTINATION/Contents/Resources/new-version" ]
[ -f "$ROLLBACK_ARCHIVE" ]

SUCCESS_ARCHIVE="$UPDATER_FIXTURE/success.zip"
/bin/cp "$FAIL_ARCHIVE" "$SUCCESS_ARCHIVE"
SUCCESS_SHA=$(/usr/bin/shasum -a 256 "$SUCCESS_ARCHIVE" | /usr/bin/awk '{ print $1 }')
SUCCESS_READY=$(make_ready_handshake "$UPDATER_FIXTURE/success-ready")
PROXYGAUGE_UPDATER_TEST_MODE=1 "$PROJECT_ROOT/Scripts/proxygauge-updater.sh" \
  "$SUCCESS_ARCHIVE" "$SUCCESS_SHA" 1.6.3 "$DESTINATION" 2147483647 "$(/usr/bin/id -u)" \
  "$SUCCESS_READY" "$READY_NONCE"
[ -f "$DESTINATION/Contents/Resources/new-version" ]
[ ! -e "$DESTINATION/Contents/Resources/old-version" ]
[ ! -e "$SUCCESS_ARCHIVE" ]

/bin/cat > "$TEMP_ROOT/UpdaterTests.swift" <<'SWIFT'
import Darwin
import Foundation

@main
struct UpdaterTests {
    static func main() async {
        precondition(AppVersion.compare("1.6.0", "1.5.7") == .orderedDescending)
        precondition(AppVersion.compare("1.5.7", "1.5.7") == .orderedSame)
        precondition(AppVersion.isValid("2.0.1"))
        precondition(!AppVersion.isValid("2.0"))
        precondition(!AppVersion.isValid("999999999999999999999999999999999.0.1"))
        let digest = String(repeating: "a", count: 64)
        let checksums = "\(digest)  ProxyGauge-1.6.0-macOS-arm64.zip\n"
        precondition(AppUpdateService.checksum(
            for: "ProxyGauge-1.6.0-macOS-arm64.zip",
            in: checksums
        ) == digest)
        precondition(AppUpdateService.checksum(
            for: "ProxyGauge-1.6.0-macOS-arm64.zip",
            in: checksums + checksums
        ) == nil)
        precondition(AppUpdateService.checksum(for: "other.zip", in: checksums) == nil)

        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let stale = cacheRoot.appendingPathComponent("1.6.2-\(UUID().uuidString)")
        let unrelated = cacheRoot.appendingPathComponent("1.6.1-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: stale, withIntermediateDirectories: false)
        try! fileManager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try! Data("ProxyGauge update cache v1\n".utf8).write(
            to: stale.appendingPathComponent(AppUpdateService.downloadMarkerName)
        )
        try! AppUpdateService.cleanupDownloadDirectories(in: cacheRoot, fileManager: fileManager)
        precondition(!fileManager.fileExists(atPath: stale.path))
        precondition(fileManager.fileExists(atPath: unrelated.path))

        let bootstrapFile = cacheRoot.appendingPathComponent("root-bootstrap.sh")
        try! AppUpdateService.rootBootstrap.write(to: bootstrapFile, atomically: true, encoding: .utf8)
        let bootstrapSyntax = Process()
        bootstrapSyntax.executableURL = URL(fileURLWithPath: "/bin/bash")
        bootstrapSyntax.arguments = ["-n", bootstrapFile.path]
        try! bootstrapSyntax.run()
        bootstrapSyntax.waitUntilExit()
        precondition(bootstrapSyntax.terminationStatus == 0)

        let appleScriptFile = cacheRoot.appendingPathComponent("administrator.applescript")
        let compiledAppleScript = cacheRoot.appendingPathComponent("administrator.scpt")
        try! AppUpdateService.administratorAppleScript.write(
            to: appleScriptFile,
            atomically: true,
            encoding: .utf8
        )
        let appleScriptSyntax = Process()
        appleScriptSyntax.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        appleScriptSyntax.arguments = ["-o", compiledAppleScript.path, appleScriptFile.path]
        try! appleScriptSyntax.run()
        appleScriptSyntax.waitUntilExit()
        precondition(appleScriptSyntax.terminationStatus == 0)

        let nonce = String(repeating: "a", count: 64)
        let readyDirectory = cacheRoot.appendingPathComponent("ready-valid")
        try! fileManager.createDirectory(
            at: readyDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let readyMarker = readyDirectory.appendingPathComponent(
            AppUpdateService.installerReadyMarkerName
        )
        try! Data("\(nonce)\n".utf8).write(to: readyMarker, options: [.atomic])
        try! fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyMarker.path)
        precondition(AppUpdateService.isInstallerReadyMarkerValid(
            at: readyMarker,
            nonce: nonce,
            expectedOwner: getuid()
        ))

        let readyProcess = Process()
        readyProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        readyProcess.arguments = ["1"]
        try! readyProcess.run()
        try! await AppUpdateService.waitForInstallerReady(
            process: readyProcess,
            marker: readyMarker,
            nonce: nonce,
            expectedOwner: getuid(),
            timeout: .seconds(1)
        )
        readyProcess.terminate()
        readyProcess.waitUntilExit()

        let failedDirectory = cacheRoot.appendingPathComponent("ready-failed")
        try! fileManager.createDirectory(
            at: failedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let failedProcess = Process()
        failedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try! failedProcess.run()
        do {
            try await AppUpdateService.waitForInstallerReady(
                process: failedProcess,
                marker: failedDirectory.appendingPathComponent(AppUpdateService.installerReadyMarkerName),
                nonce: nonce,
                expectedOwner: getuid(),
                timeout: .seconds(1)
            )
            preconditionFailure("Exited installer without a ready marker must fail")
        } catch AppUpdateError.installerPreparationFailed {
            // Expected: administrator cancellation and preparation failures return to the model.
        } catch {
            preconditionFailure("Unexpected installer failure: \(error)")
        }

        let timeoutDirectory = cacheRoot.appendingPathComponent("ready-timeout")
        try! fileManager.createDirectory(
            at: timeoutDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let timeoutProcess = Process()
        timeoutProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        timeoutProcess.arguments = ["1"]
        try! timeoutProcess.run()
        do {
            try await AppUpdateService.waitForInstallerReady(
                process: timeoutProcess,
                marker: timeoutDirectory.appendingPathComponent(AppUpdateService.installerReadyMarkerName),
                nonce: nonce,
                expectedOwner: getuid(),
                timeout: .milliseconds(20)
            )
            preconditionFailure("Installer preparation timeout must fail")
        } catch AppUpdateError.installerPreparationTimedOut {
            // Expected.
        } catch {
            preconditionFailure("Unexpected installer timeout error: \(error)")
        }
        timeoutProcess.terminate()
        timeoutProcess.waitUntilExit()

        try! Data("wrong\n".utf8).write(to: readyMarker, options: [.atomic])
        precondition(!AppUpdateService.isInstallerReadyMarkerValid(
            at: readyMarker,
            nonce: nonce,
            expectedOwner: getuid()
        ))
    }
}
SWIFT

/usr/bin/xcrun swiftc \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/BundledResourceIntegrity.swift" \
  "$PROJECT_ROOT/Sources/UpdateService.swift" \
  "$TEMP_ROOT/UpdaterTests.swift" \
  -o "$TEMP_ROOT/updater-tests"
"$TEMP_ROOT/updater-tests"

echo 'ProxyGauge updater tests passed.'
