#if CLIPBOARD_CHECK
import AppKit

@main
struct ClipboardCheck {
    static func main() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        guard !ExitClipboard.copy("正在读取…", to: pasteboard) else {
            throw ClipboardError.placeholderAccepted
        }
        guard ExitClipboard.copy(" 203.0.113.8\n", to: pasteboard) else {
            throw ClipboardError.writeFailed
        }
        guard pasteboard.string(forType: .string) == "203.0.113.8" else {
            throw ClipboardError.contentMismatch
        }
        guard ExitClipboard.copy("2001:db8::8", to: pasteboard),
              pasteboard.string(forType: .string) == "2001:db8::8" else {
            throw ClipboardError.ipv6Failed
        }
        print("ProxyGauge clipboard tests passed.")
    }

    private enum ClipboardError: Error {
        case placeholderAccepted
        case writeFailed
        case contentMismatch
        case ipv6Failed
    }
}
#endif
