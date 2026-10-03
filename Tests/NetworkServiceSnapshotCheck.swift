import Foundation

@main
struct NetworkServiceSnapshotCheck {
    static func main() {
        func observation(_ id: String = "a", provider: String = "com.liguangming.Shadowrocket",
                         state: String = "connected", ipv4: String? = "utun4",
                         ipv6: String? = "utun4") -> NetworkServiceObservation {
            NetworkServiceObservation(identifier: id, provider: provider, state: state,
                                      ipv4Interface: ipv4, ipv6Interface: ipv6)
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        require(NetworkServiceSnapshot.encode(nil) == "status\tunavailable\n", "read failure must be unavailable")
        require(NetworkServiceSnapshot.encode([]) == "status\tok\n", "no configured services is valid")
        require(NetworkServiceSnapshot.encode([observation()]) ==
                "status\tok\nservice\ta\tcom.liguangming.Shadowrocket\tconnected\tutun4\tutun4\n", "connected ownership fields")
        for state in ["disconnected", "connecting", "disconnecting"] {
            require(NetworkServiceSnapshot.encode([observation(state: state)]).hasSuffix("\tnone\tnone\n"), "inactive service must drop stale interfaces")
        }
        for invalid in [observation("a\nb"), observation(provider: "x\ty"), observation(state: "invalid"),
                        observation(ipv4: "utun4\tutun5"), observation(ipv6: "")] {
            require(NetworkServiceSnapshot.encode([invalid]) == "status\tunavailable\n", "malformed field must invalidate entire snapshot")
        }
        require(NetworkServiceSnapshot.encode([observation(), observation()]) == "status\tunavailable\n", "duplicate service IDs ambiguous")
        require(NetworkServiceSnapshot.encode([observation("b"), observation("a")]) ==
                NetworkServiceSnapshot.encode([observation("a"), observation("b")]), "stable enumeration order")
        require(NetworkServiceSnapshot.encode([observation(ipv4: nil, ipv6: nil)]).hasSuffix("\tnone\tnone\n"), "missing interfaces remain missing")
        // Conflicting family evidence must survive serialization for the consumer
        // to reject it; the encoder must not pick whichever family came first.
        require(NetworkServiceSnapshot.encode([observation(ipv4: "utun4", ipv6: "utun9")]).hasSuffix("\tutun4\tutun9\n"), "preserve family disagreement")
        print("Network service snapshot checks passed (missing, malformed, duplicate, lifecycle, order and family evidence).")
    }
}
