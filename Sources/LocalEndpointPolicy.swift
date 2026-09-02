import Darwin
import Foundation

enum LocalEndpointPolicy {
    static func normalize(_ endpoint: String) -> String? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == endpoint, !value.isEmpty,
              let separator = value.lastIndex(of: ":") else { return nil }

        var host = String(value[..<separator])
        let portText = String(value[value.index(after: separator)...])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty,
              !portText.isEmpty,
              portText.allSatisfy(\.isNumber),
              let port = Int(portText),
              (1...65535).contains(port) else { return nil }

        if host.caseInsensitiveCompare("localhost") == .orderedSame {
            return "127.0.0.1:\(port)"
        }

        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let firstByte = withUnsafeBytes(of: &ipv4) { $0[0] }
            guard firstByte == 127,
                  let rendered = render(&ipv4, family: AF_INET, size: Int(INET_ADDRSTRLEN)) else {
                return nil
            }
            return "\(rendered):\(port)"
        }

        guard !host.contains("%") else { return nil }
        var ipv6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1,
              withUnsafeBytes(of: &ipv6, { bytes in
                  bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
              }) else { return nil }
        return "[::1]:\(port)"
    }

    private static func render<T>(_ address: inout T, family: Int32, size: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: size)
        let result = withUnsafePointer(to: &address) { pointer in
            inet_ntop(family, UnsafeRawPointer(pointer), &buffer, socklen_t(size))
        }
        return result.map { _ in String(cString: buffer) }
    }
}
