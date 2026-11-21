import Foundation
import os

/// Append-only diagnostic log shared by the app UI and its services.
///
/// The dashboard is deliberately quiet while everything works, which leaves
/// nothing to inspect after the fact when it does not. PGLog writes one
/// timestamped line per event to ~/Library/Logs/ProxyGauge/app.log and
/// rotates by size, so a session can always be reconstructed later without
/// a debugger. Payloads follow the app's privacy stance: statuses, exit
/// codes, endpoints and exit IPs — never subscriptions or node secrets.
///
/// Timestamps are formatted inside the serial queue so ordering in the file
/// always matches enqueue order and the shared formatter is never touched
/// from two threads. Write failures surface once via os_log instead of
/// dying silently.
enum PGLog {
    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.valenlan.proxygauge.log")
    private static let osLog = OSLog(subsystem: "com.valenlan.proxygauge", category: "pglog")
    private static var reportedWriteFailure = false

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
        enqueue(level: "INFO", category: category, message: message)
    }

    static func error(_ category: String, _ message: String) {
        enqueue(level: "ERROR", category: category, message: message)
    }

    /// One-line session marker so later reads can find session boundaries fast.
    static func sessionStart() {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        info("lifecycle", "session start version=\(version) system=\"\(system)\"")
    }

    /// Blocks until every queued line is on disk. Called from
    /// applicationWillTerminate so the final "session end" line survives.
    static func flush() {
        queue.sync {}
    }

    private static func enqueue(level: String, category: String, message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let url = logFileURL
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            reportFailure(error)
            return
        }
        rotateIfNeeded(manager, url)
        guard let data = line.data(using: .utf8) else { return }
        // Append-only: create the file if missing, then open for append.
        // Never fall back to data.write(to:) — that truncates an existing log.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            reportFailure(nil)
            return
        }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEndOffset()
            try handle.write(contentsOf: data)
        } catch {
            reportFailure(error)
        }
    }

    /// Report the first write failure to the unified log so Console can show
    /// that logging itself is broken (disk full, permissions, ...).
    private static func reportFailure(_ error: Error?) {
        guard !reportedWriteFailure else { return }
        reportedWriteFailure = true
        os_log("PGLog write failed: %{public}@",
               log: osLog,
               type: .error,
               error.map { String(describing: $0) } ?? "cannot open log file")
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
