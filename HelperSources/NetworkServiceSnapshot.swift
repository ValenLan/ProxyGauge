import Foundation

// The wire format contains only OS service identity and interface state, never
// VPN names, credentials, server addresses, or provider configuration.
struct NetworkServiceObservation {
    let identifier: String
    let provider: String
    let state: String
    let ipv4Interface: String?
    let ipv6Interface: String?
}

enum NetworkServiceSnapshot {
    static func encode(_ observations: [NetworkServiceObservation]?) -> String {
        guard let observations else { return "status\tunavailable\n" }
        var identifiers = Set<String>()
        var rows = [String]()
        for item in observations {
            guard validIdentity(item.identifier), validIdentity(item.provider),
                  identifiers.insert(item.identifier).inserted,
                  ["connected", "disconnected", "connecting", "disconnecting"].contains(item.state),
                  validInterface(item.ipv4Interface), validInterface(item.ipv6Interface) else {
                return "status\tunavailable\n"
            }
            // Only a connected service may supply ownership evidence. Stale
            // extended status while a service is stopping is not active state.
            let connected = item.state == "connected"
            rows.append(["service", item.identifier, item.provider, item.state,
                         connected ? item.ipv4Interface ?? "none" : "none",
                         connected ? item.ipv6Interface ?? "none" : "none"].joined(separator: "\t"))
        }
        return (["status\tok"] + rows.sorted()).joined(separator: "\n") + "\n"
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value)
                || (97...122).contains($0.value) || [45, 46, 95].contains($0.value)
        }
    }

    private static func validInterface(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 32 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value)
                || (97...122).contains($0.value) || [45, 95].contains($0.value)
        }
    }
}
