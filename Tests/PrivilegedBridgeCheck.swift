import Foundation

@main
struct PrivilegedBridgeCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxygauge-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = root.appendingPathComponent("fixture")
        try Data("trusted fixture".utf8).write(to: fixture, options: .atomic)
        let digest = try BundledResourceIntegrity.sha256(of: fixture)
        try BundledResourceIntegrity.validateRegularFile(at: fixture, expectedSHA256: digest)

        let symlink = root.appendingPathComponent("fixture-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture)
        try requireThrows("A symlink must not pass bundled-resource validation.") {
            try BundledResourceIntegrity.validateRegularFile(at: symlink, expectedSHA256: digest)
        }
        try requireThrows("A wrong digest must fail closed.") {
            try BundledResourceIntegrity.validateRegularFile(
                at: fixture,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        }

        let bootstrap = KillSwitchAdminService.rootBootstrap
        try require(
            shellSyntaxIsValid(bootstrap),
            "The embedded Kill Switch root bootstrap must be valid bash syntax."
        )
        try requireOrdered(
            in: bootstrap,
            [
                "install -o root -g wheel -m 700 \"$helper_source\" \"$staged_helper\"",
                "shasum -a 256 \"$staged_helper\"",
                "mv -f \"$helper_tmp\" \"$fixed_helper\"",
                "shasum -a 256 \"$fixed_helper\"",
                "env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            "Kill Switch bytes must be staged, verified, atomically installed, re-verified, then executed."
        )
        try require(
            KillSwitchAdminService.administratorAppleScript.contains(
                "/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.killswitch.lock"
            ),
            "Administrator actions must share the root-only Kill Switch lock."
        )
        try require(
            !bootstrap.contains("$HOME") && !bootstrap.contains("sudo"),
            "The privileged bootstrap must not trust a user home or recursively elevate itself."
        )

        let updaterBootstrap = AppUpdateService.rootBootstrap
        try require(
            shellSyntaxIsValid(updaterBootstrap),
            "The embedded updater root bootstrap must be valid bash syntax."
        )
        try requireOrdered(
            in: updaterBootstrap,
            [
                "install -o root -g wheel -m 700 \"$updater_source\" \"$staged_updater\"",
                "install -o root -g wheel -m 600 \"$archive_source\" \"$staged_archive\"",
                "shasum -a 256 \"$staged_archive\"",
                "env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            "The privileged updater and archive must be copied and verified in a root-owned stage."
        )
        try require(
            AppUpdateService.administratorAppleScript.contains(
                "/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.install.lock"
            ),
            "Initial installation and privileged updates must share one root-only lock."
        )

        let invalid = await KillSwitchAdminService.invokeAdministratorBridge(
            action: "install",
            helper: fixture,
            template: fixture,
            osascript: URL(fileURLWithPath: "/usr/bin/osascript")
        )
        try require(invalid.status == 2, "The bridge must accept only on/off actions.")

        print("ProxyGauge privileged bridge integrity tests passed.")
    }

    private static func shellSyntaxIsValid(_ source: String) -> Bool {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func requireOrdered(
        in value: String,
        _ fragments: [String],
        _ message: String
    ) throws {
        var lowerBound = value.startIndex
        for fragment in fragments {
            guard let range = value.range(of: fragment, range: lowerBound..<value.endIndex) else {
                throw CheckError.failed(message)
            }
            lowerBound = range.upperBound
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }

    private static func requireThrows(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
            throw CheckError.failed(message)
        } catch is BundledResourceIntegrity.IntegrityError {
            return
        }
    }

    private enum CheckError: Error {
        case failed(String)
    }
}
