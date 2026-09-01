import Darwin

enum IPAddressVersion: String, Equatable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"

    static func parse(_ address: String) -> IPAddressVersion? {
        guard !address.isEmpty, !address.utf8.contains(0) else { return nil }

        if isStrictIPv4(address) {
            return .ipv4
        }

        guard !address.contains("%") else { return nil }

        if address.contains(".") {
            guard let separator = address.lastIndex(of: ":"),
                  isStrictIPv4(String(address[address.index(after: separator)...])) else {
                return nil
            }
        }

        var ipv6Address = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 {
            return .ipv6
        }

        return nil
    }

    private static func isStrictIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        return octets.allSatisfy { octet in
            let bytes = Array(octet.utf8)
            guard !bytes.isEmpty,
                  bytes.count <= 3,
                  bytes.allSatisfy({ (48...57).contains($0) }),
                  !(bytes.count > 1 && bytes[0] == 48) else {
                return false
            }

            return bytes.reduce(0) { ($0 * 10) + Int($1 - 48) } <= 255
        }
    }
}
