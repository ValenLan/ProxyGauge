import Foundation

/// Append-only diagnostic log shared by the app UI and its services.
///
/// The dashboard is deliberately quiet while everything works, which leaves
/// nothing to inspect after the fact when it does not. PGLog writes one
/// timestamped line per event to ~/Library/Logs/ProxyGauge/app.log and
/// rotates by size, so a session can always be reconstructed later without
/// a debugger. Payloads follow the app's privacy stance: statuses, exit
/// codes, endpoints and exit IPs — never subscriptions or node secrets.
enum PGLog {
    private static let maxBytes = 512 * 1024
    private static let rotatedGenerations = 3
    private static let queue = DispatchQueue(label: "com.valenlan.proxygauge.log")

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var logFileURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ProxyGauge/app.log")
    }

    static func info(_ category: String, _ message: String) {
        write(level: "INFO", category: category, message: message)
    }

    static func error(_ category: String, _ message: String) {
        write(level: "ERROR", category: category, message: message)
    }

    /// One-line session marker so later reads can find session boundaries fast.
    static func sessionStart() {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        info("lifecycle", "session start version=\(version) system=\"\(system)\"")
    }

    private static func write(level: String, category: String, message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async {
            let url = logFileURL
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(manager, url)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Size-capped rotation: app.log → app.log.0 → app.log.1 → app.log.2 (dropped).
    private static func rotateIfNeeded(_ manager: FileManager, _ url: URL) {
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= maxBytes else { return }
        try? manager.removeItem(at: url.appendingPathExtension("2"))
        try? manager.moveItem(
            at: url.appendingPathExtension("1"),
            to: url.appendingPathExtension("2")
        )
        try? manager.moveItem(
            at: url.appendingPathExtension("0"),
            to: url.appendingPathExtension("1")
        )
        try? manager.moveItem(at: url, to: url.appendingPathExtension("0"))
    }
}
