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
        version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func components(_ value: String) -> [Int] {
        value.split(separator: ".").map { Int($0) ?? 0 }
    }
}

enum AppUpdateError: LocalizedError {
    case invalidResponse
    case invalidRelease
    case missingAsset(String)
    case checksumMissing
    case checksumMismatch
    case unsupportedInstallLocation
    case missingInstallerHelper

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "更新服务器没有返回有效响应。"
        case .invalidRelease: return "最新 Release 的版本信息无效。"
        case .missingAsset(let name): return "最新 Release 缺少 \(name)。"
        case .checksumMissing: return "SHA256SUMS.txt 中没有当前更新包的校验值。"
        case .checksumMismatch: return "更新包 SHA-256 校验失败，安装已停止。"
        case .unsupportedInstallLocation: return "当前运行位置不是可更新的 ProxyGauge.app。"
        case .missingInstallerHelper: return "应用内缺少更新安装组件。"
        }
    }
}

struct AppUpdateService: Sendable {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/ValenLan/ProxyGauge/releases/latest"
    )!

    func check(currentVersion: String) async throws -> AppUpdateRelease? {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ProxyGauge-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, release.tagName.hasPrefix("v") else {
            throw AppUpdateError.invalidRelease
        }
        let version = String(release.tagName.dropFirst())
        guard AppVersion.isValid(version) else { throw AppUpdateError.invalidRelease }
        guard AppVersion.compare(version, currentVersion) == .orderedDescending else { return nil }

        let archiveName = "ProxyGauge-\(version)-macOS-arm64.zip"
        guard let archive = release.assets.first(where: { $0.name == archiveName }) else {
            throw AppUpdateError.missingAsset(archiveName)
        }
        guard let checksums = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else {
            throw AppUpdateError.missingAsset("SHA256SUMS.txt")
        }
        return AppUpdateRelease(
            version: version,
            releaseNotes: release.body ?? "",
            archiveURL: archive.browserDownloadURL,
            checksumURL: checksums.browserDownloadURL
        )
    }

    func download(_ release: AppUpdateRelease) async throws -> (archive: URL, checksum: String) {
        let fileManager = FileManager.default
        let root = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
            .appendingPathComponent("ProxyGauge", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent(release.version, isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let archiveName = "ProxyGauge-\(release.version)-macOS-arm64.zip"
        let archive = root.appendingPathComponent(archiveName)
        let (temporaryArchive, archiveResponse) = try await URLSession.shared.download(from: release.archiveURL)
        try Self.validate(archiveResponse)
        try fileManager.moveItem(at: temporaryArchive, to: archive)

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        try Self.validate(checksumResponse)
        let checksumText = String(decoding: checksumData, as: UTF8.self)
        guard let expected = Self.checksum(for: archiveName, in: checksumText) else {
            throw AppUpdateError.checksumMissing
        }
        let actual = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else { throw AppUpdateError.checksumMismatch }
        return (archive, expected)
    }

    @MainActor
    func installDownloadedUpdate(
        _ release: AppUpdateRelease,
        archive: URL,
        checksum: String
    ) throws {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app", bundleURL.lastPathComponent == "ProxyGauge.app" else {
            throw AppUpdateError.unsupportedInstallLocation
        }
        guard let helper = Bundle.main.url(forResource: "proxygauge-updater", withExtension: "sh") else {
            throw AppUpdateError.missingInstallerHelper
        }

        let arguments = [
            archive.path,
            checksum,
            release.version,
            bundleURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            String(getuid())
        ]
        let parent = bundleURL.deletingLastPathComponent().path
        let process = Process()
        if FileManager.default.isWritableFile(atPath: parent) {
            process.executableURL = helper
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let command = ([helper.path] + arguments).map(Self.shellQuote).joined(separator: " ")
            let script = "do shell script \(Self.appleScriptQuote(command)) with administrator privileges"
            process.arguments = ["-e", script]
            var environment = ProcessInfo.processInfo.environment
            environment["PROXYGAUGE_UPDATE_LOG_HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = environment
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    static func checksum(for assetName: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(whereSeparator: \Character.isWhitespace)
            guard parts.count >= 2 else { continue }
            let digest = String(parts[0]).lowercased()
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == assetName,
               digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil {
                return digest
            }
        }
        return nil
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.invalidResponse
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
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
