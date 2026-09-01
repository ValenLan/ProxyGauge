import Foundation

@main
struct IPAddressVersionCheck {
    static func main() throws {
        let cases: [(address: String, expected: IPAddressVersion?)] = [
            ("198.51.100.24", .ipv4),
            ("0.0.0.0", .ipv4),
            ("255.255.255.255", .ipv4),
            ("2001:db8::8", .ipv6),
            ("2001:DB8::8", .ipv6),
            ("::1", .ipv6),
            ("::ffff:192.0.2.128", .ipv6),
            ("", nil),
            ("正在读取…", nil),
            ("暂时无法读取", nil),
            ("198.51.100.24 ", nil),
            (" 198.51.100.24", nil),
            ("198.51.100.024", nil),
            ("256.51.100.24", nil),
            ("198.51.100.24:443", nil),
            ("[2001:db8::8]", nil),
            ("fe80::1%en0", nil),
            ("2001:db8::g", nil),
            ("2001:db8::8 ", nil),
            ("2001:db8::8\n", nil),
            ("198.51.100.24\0ignored", nil)
        ]

        for testCase in cases {
            let actual = IPAddressVersion.parse(testCase.address)
            guard actual == testCase.expected else {
                throw CheckError.unexpectedResult(
                    address: testCase.address,
                    expected: testCase.expected?.rawValue,
                    actual: actual?.rawValue
                )
            }
        }

        print("ProxyGauge local IP address version tests passed.")
    }

    private enum CheckError: Error {
        case unexpectedResult(address: String, expected: String?, actual: String?)
    }
}
