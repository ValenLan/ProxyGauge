import AppKit
import Darwin

enum ExitClipboard {
    static func normalizedAddress(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPAddress(value) else { return nil }
        return value
    }

    static func copy(_ rawValue: String, to pasteboard: NSPasteboard = .general) -> Bool {
        copy(rawValue) { value in
            let item = NSPasteboardItem()
            guard item.setString(value, forType: .string) else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        }
    }

    static func copy(_ rawValue: String, using writer: (String) -> Bool) -> Bool {
        guard let value = normalizedAddress(rawValue) else { return false }
        return writer(value)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}
