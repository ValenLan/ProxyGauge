@main
struct ClipboardCheck {
    static func main() throws {
        var copiedValue: String?
        let writer: (String) -> Bool = { value in
            copiedValue = value
            return true
        }

        guard !ExitClipboard.copy("正在读取…", using: writer), copiedValue == nil else {
            throw ClipboardError.placeholderAccepted
        }
        guard ExitClipboard.copy(" 203.0.113.8\n", using: writer) else {
            throw ClipboardError.writeFailed
        }
        guard copiedValue == "203.0.113.8" else {
            throw ClipboardError.contentMismatch
        }
        guard ExitClipboard.copy("2001:db8::8", using: writer),
              copiedValue == "2001:db8::8" else {
            throw ClipboardError.ipv6Failed
        }
        guard !ExitClipboard.copy("8.8.8.8", using: { _ in false }) else {
            throw ClipboardError.writeFailureIgnored
        }
        print("ProxyGauge clipboard tests passed.")
    }

    private enum ClipboardError: Error {
        case placeholderAccepted
        case writeFailed
        case contentMismatch
        case ipv6Failed
        case writeFailureIgnored
    }
}
