import CryptoKit
import Darwin
import Foundation

enum BundledResourceIntegrity {
    // These digests are release inputs compiled into the running executable.
    // Scripts/build.sh refuses to package resources that do not match them.
    static let backendSHA256 = "__UPDATE_BACKEND_SHA256__"
    static let killSwitchHelperSHA256 = "__UPDATE_KILLSWITCH_SHA256__"
    static let killSwitchTemplateSHA256 = "__UPDATE_KILLSWITCH_TEMPLATE_SHA256__"
    static let updaterSHA256 = "__UPDATE_UPDATER_SHA256__"
    static let trustedBundlePath = "/Library/Application Support/ProxyGauge/ProxyGauge.app"

    static func validatePrivilegedBundle(_ bundle: Bundle) throws {
        let resolvedBundle = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBundle.path == trustedBundlePath else {
            throw IntegrityError.untrustedInstallLocation
        }
        guard let executable = bundle.executableURL?.resolvingSymlinksInPath() else {
            throw IntegrityError.untrustedInstallLocation
        }
        let paths = [
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/ProxyGauge", isDirectory: true),
            resolvedBundle,
            resolvedBundle.appendingPathComponent("Contents", isDirectory: true),
            resolvedBundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            resolvedBundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            executable
        ]
        for url in paths {
            try validateRootOwnedPath(url)
        }
    }

    static func validateRegularFile(at url: URL, expectedSHA256: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw IntegrityError.notRegularFile(url.lastPathComponent)
        }
        let actual = try sha256(of: url)
        guard actual == expectedSHA256 else {
            throw IntegrityError.digestMismatch(url.lastPathComponent)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validateRootOwnedPath(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG || (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0,
              !hasExtendedACL(url.path) else {
            throw IntegrityError.insecureOwnership(url.lastPathComponent)
        }
    }

    private static func hasExtendedACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT && errno != ENOTSUP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        return result != 1
    }

    enum IntegrityError: LocalizedError {
        case notRegularFile(String)
        case digestMismatch(String)
        case untrustedInstallLocation
        case insecureOwnership(String)

        var errorDescription: String? {
            switch self {
            case .notRegularFile(let name):
                return "内置组件 \(name) 不是安全的普通文件，操作已停止。"
            case .digestMismatch(let name):
                return "内置组件 \(name) 完整性校验失败，操作已停止。请从正式渠道重新安装。"
            case .untrustedInstallLocation:
                return "当前应用不是正式安装目录中的受保护副本，不能执行管理员操作。请通过正式安装器重新安装。"
            case .insecureOwnership(let name):
                return "正式安装路径 \(name) 的所有者、权限或 ACL 不安全，不能执行管理员操作。"
            }
        }
    }
}
