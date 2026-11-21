import AppKit
import CryptoKit
import Darwin
import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    let version: String
    let releaseNotes: String
    let archiveURL: URL
    let checksumURL: URL
}

enum AppVersion {
    static func compare(_ first: String, _ second: String) -> ComparisonResult {
        let lhs = components(first)
        let rhs = components(second)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    static func isValid(_ version: String) -> Bool {
        guard version.utf8.count <= 32,
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }
        return version.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    private static func components(_ value: String) -> [Int] {
        value.split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum AppUpdateError: LocalizedError {
    case invalidResponse
    case invalidRelease
    case untrustedDownload
    case responseTooLarge
    case invalidChecksumFile
    case missingAsset(String)
    case checksumMissing
    case checksumMismatch
    case unsupportedInstallLocation
    case missingInstallerHelper
    case installerPreparationFailed
    case installerPreparationTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "更新服务器没有返回有效响应。"
        case .invalidRelease: return "最新 Release 的版本信息无效。"
        case .untrustedDownload: return "更新地址不属于 ProxyGauge 官方 GitHub Release。"
        case .responseTooLarge: return "更新服务器返回的数据超过安全大小限制。"
        case .invalidChecksumFile: return "SHA256SUMS.txt 不是有效的 UTF-8 文件。"
        case .missingAsset(let name): return "最新 Release 缺少 \(name)。"
        case .checksumMissing: return "SHA256SUMS.txt 中没有当前更新包的校验值。"
        case .checksumMismatch: return "更新包 SHA-256 校验失败，安装已停止。"
        case .unsupportedInstallLocation: return "当前运行位置不是可更新的 ProxyGauge.app。"
        case .missingInstallerHelper: return "应用内缺少更新安装组件。"
        case .installerPreparationFailed: return "更新安装程序未能完成安全准备，应用仍保持运行。"
        case .installerPreparationTimedOut: return "等待更新安装程序完成安全准备超时，应用仍保持运行。"
        }
    }
}

private final class AppUpdateRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let lock = NSLock()
    private var redirectCount = 0

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        guard count <= 5,
              let url = request.url,
              AppUpdateService.isAllowedHTTPSURL(url, hosts: allowedHosts) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct AppUpdateService: Sendable {
    private static let repository = "ValenLan/ProxyGauge"
    private static let apiHosts: Set<String> = ["api.github.com"]
    private static let assetHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com"
    ]
    private static let releaseMetadataLimit = 2 * 1_024 * 1_024
    private static let checksumLimit = 1 * 1_024 * 1_024
    private static let archiveLimit = 512 * 1_024 * 1_024
    static let downloadMarkerName = ".com.valenlan.proxygauge-update"
    static let installerReadyMarkerName = "ready"
    private static let downloadMarkerContents = Data("ProxyGauge update cache v1\n".utf8)
    private static let installerReadyTimeout: Duration = .seconds(600)
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/ValenLan/ProxyGauge/releases/latest"
    )!

    func check(currentVersion: String) async throws -> AppUpdateRelease? {
        guard AppVersion.isValid(currentVersion) else { throw AppUpdateError.invalidRelease }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ProxyGauge-Updater", forHTTPHeaderField: "User-Agent")
        let data = try await Self.downloadData(
            request: request,
            allowedHosts: Self.apiHosts,
            maximumBytes: Self.releaseMetadataLimit,
            timeout: 60,
            exactFinalURL: Self.latestReleaseURL
        )

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, release.tagName.hasPrefix("v") else {
            throw AppUpdateError.invalidRelease
        }
        let version = String(release.tagName.dropFirst())
        guard AppVersion.isValid(version) else { throw AppUpdateError.invalidRelease }
        guard AppVersion.compare(version, currentVersion) == .orderedDescending else { return nil }

        let archiveName = "ProxyGauge-\(version)-macOS-arm64.zip"
        let archive = try Self.exactAsset(named: archiveName, in: release, version: version)
        let checksums = try Self.exactAsset(named: "SHA256SUMS.txt", in: release, version: version)
        return AppUpdateRelease(
            version: version,
            releaseNotes: release.body ?? "",
            archiveURL: archive.browserDownloadURL,
            checksumURL: checksums.browserDownloadURL
        )
    }

    func download(_ release: AppUpdateRelease) async throws -> (archive: URL, checksum: String) {
        let fileManager = FileManager.default
        let updatesRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
            .appendingPathComponent("ProxyGauge", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: updatesRoot, withIntermediateDirectories: true)
        try Self.cleanupDownloadDirectories(in: updatesRoot, fileManager: fileManager)
        let root = updatesRoot.appendingPathComponent(
            "\(release.version)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        do {
            let marker = root.appendingPathComponent(Self.downloadMarkerName, isDirectory: false)
            try Self.downloadMarkerContents.write(to: marker, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            let archiveName = "ProxyGauge-\(release.version)-macOS-arm64.zip"
            let archive = root.appendingPathComponent(archiveName)
            try Self.validateReleaseAssetURL(release.checksumURL, name: "SHA256SUMS.txt", version: release.version)
            try Self.validateReleaseAssetURL(release.archiveURL, name: archiveName, version: release.version)

            let checksumData = try await Self.downloadData(
                request: Self.releaseRequest(url: release.checksumURL),
                allowedHosts: Self.assetHosts,
                maximumBytes: Self.checksumLimit,
                timeout: 60
            )
            guard let checksumText = String(data: checksumData, encoding: .utf8) else {
                throw AppUpdateError.invalidChecksumFile
            }
            guard let expected = Self.checksum(for: archiveName, in: checksumText) else {
                throw AppUpdateError.checksumMissing
            }

            try await Self.downloadFile(
                request: Self.releaseRequest(url: release.archiveURL),
                destination: archive,
                allowedHosts: Self.assetHosts,
                maximumBytes: Self.archiveLimit,
                timeout: 600
            )
            let actual = try Self.sha256(of: archive)
            guard actual == expected else { throw AppUpdateError.checksumMismatch }
            return (archive, expected)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    @MainActor
    func installDownloadedUpdate(
        _ release: AppUpdateRelease,
        archive: URL,
        checksum: String
    ) async throws {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundleURL.pathExtension == "app", bundleURL.lastPathComponent == "ProxyGauge.app" else {
            throw AppUpdateError.unsupportedInstallLocation
        }
        guard let helper = Bundle.main.url(forResource: "proxygauge-updater", withExtension: "sh") else {
            throw AppUpdateError.missingInstallerHelper
        }
        try BundledResourceIntegrity.validateRegularFile(
            at: helper,
            expectedSHA256: BundledResourceIntegrity.updaterSHA256
        )
        try BundledResourceIntegrity.validateRegularFile(at: archive, expectedSHA256: checksum)

        let nonce = Self.makeInstallerReadyNonce()
        let protectedInstall = !FileManager.default.isWritableFile(
            atPath: bundleURL.deletingLastPathComponent().path
        )
        let readyDirectory: URL
        let expectedReadyOwner: uid_t
        if protectedInstall {
            readyDirectory = URL(
                fileURLWithPath: "/private/var/tmp/com.valenlan.proxygauge-update-ready.\(UUID().uuidString)",
                isDirectory: true
            )
            expectedReadyOwner = 0
        } else {
            readyDirectory = archive.deletingLastPathComponent().appendingPathComponent(
                ".installer-ready-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: readyDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            expectedReadyOwner = getuid()
        }
        let readyMarker = readyDirectory.appendingPathComponent(
            Self.installerReadyMarkerName,
            isDirectory: false
        )
        defer {
            if !protectedInstall {
                try? FileManager.default.removeItem(at: readyDirectory)
            }
        }

        let arguments = [
            archive.path,
            checksum,
            release.version,
            bundleURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            String(getuid()),
            readyMarker.path,
            nonce
        ]
        let process = Process()
        if !protectedInstall {
            process.executableURL = helper
            process.arguments = arguments
            process.environment = Self.sanitizedEnvironment()
        } else {
            try BundledResourceIntegrity.validatePrivilegedBundle(.main)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", Self.administratorAppleScript,
                "--", Self.rootBootstrap,
                helper.path, BundledResourceIntegrity.updaterSHA256
            ] + Array(arguments.prefix(6)) + [readyDirectory.path, nonce]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C"
            ]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try await Self.waitForInstallerReady(
                process: process,
                marker: readyMarker,
                nonce: nonce,
                expectedOwner: expectedReadyOwner,
                timeout: Self.installerReadyTimeout
            )
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
        NSApp.terminate(nil)
    }

    static func waitForInstallerReady(
        process: Process,
        marker: URL,
        nonce: String,
        expectedOwner: uid_t,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            switch installerReadyMarkerState(
                at: marker,
                nonce: nonce,
                expectedOwner: expectedOwner
            ) {
            case .valid:
                return
            case .invalid:
                throw AppUpdateError.installerPreparationFailed
            case .missing:
                break
            }
            guard process.isRunning else {
                process.waitUntilExit()
                throw AppUpdateError.installerPreparationFailed
            }
            guard clock.now < deadline else {
                throw AppUpdateError.installerPreparationTimedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                throw AppUpdateError.installerPreparationFailed
            }
        }
    }

    static func isInstallerReadyMarkerValid(
        at marker: URL,
        nonce: String,
        expectedOwner: uid_t
    ) -> Bool {
        installerReadyMarkerState(
            at: marker,
            nonce: nonce,
            expectedOwner: expectedOwner
        ) == .valid
    }

    private enum InstallerReadyMarkerState {
        case missing
        case valid
        case invalid
    }

    private static func installerReadyMarkerState(
        at marker: URL,
        nonce: String,
        expectedOwner: uid_t
    ) -> InstallerReadyMarkerState {
        guard nonce.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              marker.lastPathComponent == installerReadyMarkerName else {
            return .invalid
        }

        let directory = marker.deletingLastPathComponent()
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 {
            return errno == ENOENT ? .missing : .invalid
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == expectedOwner,
              (directoryInfo.st_mode & 0o022) == 0 else {
            return .invalid
        }

        var markerInfo = stat()
        if lstat(marker.path, &markerInfo) != 0 {
            return errno == ENOENT ? .missing : .invalid
        }
        guard (markerInfo.st_mode & S_IFMT) == S_IFREG,
              markerInfo.st_uid == expectedOwner,
              markerInfo.st_nlink == 1,
              (markerInfo.st_mode & 0o022) == 0,
              markerInfo.st_size == nonce.utf8.count + 1,
              let contents = try? Data(contentsOf: marker, options: [.mappedIfSafe]),
              contents == Data("\(nonce)\n".utf8) else {
            return .invalid
        }
        return .valid
    }

    private static func makeInstallerReadyNonce() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func checksum(for assetName: String, in text: String) -> String? {
        var result: String?
        for line in text.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \Character.isWhitespace
            )
            guard parts.count == 2 else { continue }
            let digest = String(parts[0]).lowercased()
            let rawName = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let name = rawName.hasPrefix("*") ? String(rawName.dropFirst()) : rawName
            if name == assetName,
               digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil {
                guard result == nil else { return nil }
                result = digest
            }
        }
        return result
    }

    static func cleanupDownloadDirectories(
        in updatesRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let rootValues = try updatesRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AppUpdateError.invalidResponse
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let candidates = try fileManager.contentsOfDirectory(
            at: updatesRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            guard candidate.lastPathComponent.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Fa-f-]{36}$"#,
                options: .regularExpression
            ) != nil else { continue }
            let values = try candidate.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let marker = candidate.appendingPathComponent(downloadMarkerName, isDirectory: false)
            let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard markerValues?.isRegularFile == true,
                  markerValues?.isSymbolicLink != true,
                  let contents = try? Data(contentsOf: marker, options: [.mappedIfSafe]),
                  contents == downloadMarkerContents else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }

    fileprivate static func isAllowedHTTPSURL(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              hosts.contains(host) else { return false }
        return true
    }

    private static func validate(
        _ response: URLResponse,
        allowedHosts: Set<String>,
        maximumBytes: Int,
        exactFinalURL: URL? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              isAllowedHTTPSURL(finalURL, hosts: allowedHosts),
              exactFinalURL == nil || finalURL == exactFinalURL else {
            throw AppUpdateError.invalidResponse
        }
        if http.expectedContentLength > Int64(maximumBytes) {
            throw AppUpdateError.responseTooLarge
        }
    }

    private static func releaseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("ProxyGauge-Updater", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func exactAsset(
        named name: String,
        in release: GitHubRelease,
        version: String
    ) throws -> GitHubReleaseAsset {
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first else {
            throw AppUpdateError.missingAsset(name)
        }
        try validateReleaseAssetURL(asset.browserDownloadURL, name: name, version: version)
        return asset
    }

    private static func validateReleaseAssetURL(_ url: URL, name: String, version: String) throws {
        let expectedPath = "/\(repository)/releases/download/v\(version)/\(name)"
        guard isAllowedHTTPSURL(url, hosts: ["github.com"]),
              url.path == expectedPath,
              url.query == nil,
              url.fragment == nil else {
            throw AppUpdateError.untrustedDownload
        }
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = min(timeout, 30)
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func downloadData(
        request: URLRequest,
        allowedHosts: Set<String>,
        maximumBytes: Int,
        timeout: TimeInterval,
        exactFinalURL: URL? = nil
    ) async throws -> Data {
        guard let url = request.url, isAllowedHTTPSURL(url, hosts: allowedHosts) else {
            throw AppUpdateError.untrustedDownload
        }
        let session = makeSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let redirectDelegate = AppUpdateRedirectDelegate(allowedHosts: allowedHosts)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        try validate(
            response,
            allowedHosts: allowedHosts,
            maximumBytes: maximumBytes,
            exactFinalURL: exactFinalURL
        )
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw AppUpdateError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func downloadFile(
        request: URLRequest,
        destination: URL,
        allowedHosts: Set<String>,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async throws {
        guard let url = request.url, isAllowedHTTPSURL(url, hosts: allowedHosts) else {
            throw AppUpdateError.untrustedDownload
        }
        let fileManager = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(
            atPath: partial.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw AppUpdateError.invalidResponse }
        let handle = try FileHandle(forWritingTo: partial)
        let session = makeSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        do {
            let redirectDelegate = AppUpdateRedirectDelegate(allowedHosts: allowedHosts)
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
            try validate(response, allowedHosts: allowedHosts, maximumBytes: maximumBytes)
            var total = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                guard total < maximumBytes else { throw AppUpdateError.responseTooLarge }
                buffer.append(byte)
                total += 1
                if buffer.count == 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedEnvironment() -> [String: String] {
        let userName = NSUserName()
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": userName,
            "LOGNAME": userName,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp",
            "LC_ALL": "C"
        ]
    }

    static let rootBootstrap = #"""
    set -euo pipefail
    umask 077

    updater_source=${1:-}
    updater_expected=${2:-}
    archive_source=${3:-}
    archive_expected=${4:-}
    version=${5:-}
    destination=${6:-}
    app_pid=${7:-}
    user_id=${8:-}
    ready_dir=${9:-}
    ready_nonce=${10:-}
    [ "${#updater_expected}" -eq 64 ] && [ "${#archive_expected}" -eq 64 ] || exit 2
    case "$updater_expected$archive_expected" in *[!0-9A-Fa-f]*) exit 2 ;; esac
    [ "${#ready_nonce}" -eq 64 ] || exit 2
    case "$ready_nonce" in *[!0-9a-f]*) exit 2 ;; esac
    [[ "$ready_dir" =~ ^/private/var/tmp/com\.valenlan\.proxygauge-update-ready\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || exit 2
    [ ! -e "$ready_dir" ] && [ ! -L "$ready_dir" ] || exit 2
    [ -f "$updater_source" ] && [ ! -L "$updater_source" ] || exit 2
    [ -f "$archive_source" ] && [ ! -L "$archive_source" ] || exit 2

    stage=$(/usr/bin/mktemp -d /private/var/tmp/com.valenlan.proxygauge-update.XXXXXX)
    ready_dir_created=0
    cleanup() {
      status=$?
      trap - EXIT HUP INT TERM
      if [ "$ready_dir_created" -eq 1 ]; then
        /bin/rm -f "$ready_dir/ready"
        /bin/rmdir "$ready_dir" 2>/dev/null || true
      fi
      /bin/rm -rf "$stage"
      exit "$status"
    }
    trap cleanup EXIT HUP INT TERM
    staged_updater="$stage/proxygauge-updater.sh"
    staged_archive="$stage/ProxyGauge-update.zip"
    /usr/bin/install -o root -g wheel -m 700 "$updater_source" "$staged_updater"
    /usr/bin/install -o root -g wheel -m 600 "$archive_source" "$staged_archive"
    actual_updater=$(/usr/bin/shasum -a 256 "$staged_updater" | /usr/bin/awk '{print $1}')
    actual_archive=$(/usr/bin/shasum -a 256 "$staged_archive" | /usr/bin/awk '{print $1}')
    [ "$actual_updater" = "$updater_expected" ] || { echo "更新组件完整性校验失败。" >&2; exit 1; }
    [ "$(/usr/bin/printf '%s' "$actual_archive" | /usr/bin/tr '[:upper:]' '[:lower:]')" = "$(/usr/bin/printf '%s' "$archive_expected" | /usr/bin/tr '[:upper:]' '[:lower:]')" ] || {
      echo "更新包完整性校验失败。" >&2
      exit 1
    }
    /bin/mkdir -m 755 "$ready_dir"
    ready_dir_created=1
    /bin/chmod -N "$ready_dir"
    /usr/sbin/chown root:wheel "$ready_dir"
    /bin/chmod 755 "$ready_dir"
    [ -d "$ready_dir" ] && [ ! -L "$ready_dir" ] || exit 1
    [ "$(/usr/bin/stat -f '%u' "$ready_dir")" = 0 ] || exit 1
    ready_mode=$(/usr/bin/stat -f '%Lp' "$ready_dir")
    [ $((8#$ready_mode & 022)) -eq 0 ] || exit 1
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C HOME=/var/empty \
      "$staged_updater" "$staged_archive" "$archive_expected" "$version" \
      "$destination" "$app_pid" "$user_id" "$ready_dir/ready" "$ready_nonce"
    """#

    static let administratorAppleScript = #"""
    use scripting additions
    on run argv
        if (count of argv) is not 11 then error "Invalid ProxyGauge update arguments"
        set bootstrapText to item 1 of argv
        set updaterPath to item 2 of argv
        set updaterHash to item 3 of argv
        set archivePath to item 4 of argv
        set archiveHash to item 5 of argv
        set releaseVersion to item 6 of argv
        set destinationPath to item 7 of argv
        set appPID to item 8 of argv
        set userID to item 9 of argv
        set readyDirectory to item 10 of argv
        set readyNonce to item 11 of argv
        set commandText to "/usr/bin/lockf -k -t 120 /private/var/run/com.valenlan.proxygauge.install.lock /bin/bash -p -c " & quoted form of bootstrapText & " proxygauge-update-bootstrap " & quoted form of updaterPath & " " & quoted form of updaterHash & " " & quoted form of archivePath & " " & quoted form of archiveHash & " " & quoted form of releaseVersion & " " & quoted form of destinationPath & " " & quoted form of appPID & " " & quoted form of userID & " " & quoted form of readyDirectory & " " & quoted form of readyNonce
        «event sysoexec» commandText given «class badm»:true
    end run
    """#
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
