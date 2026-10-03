import Foundation
import SystemConfiguration

@main
struct NetworkServicesMain {
    static func main() {
        let snapshot = NetworkServiceSnapshot.encode(readServices())
        FileHandle.standardOutput.write(Data(snapshot.utf8))
    }

    // Read-only SystemConfiguration calls. Inaccessible state is unavailable;
    // neither an installed VPN nor a running provider proves tunnel ownership.
    private static func readServices() -> [NetworkServiceObservation]? {
        guard let preferences = SCPreferencesCreate(nil, "ProxyGauge Network Services" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { return nil }
        var observations = [NetworkServiceObservation]()
        for service in services {
            guard let serviceID = SCNetworkServiceGetServiceID(service) else { return nil }
            let identifier = serviceID as String
            guard let configuration = SCPreferencesPathGetValue(
                preferences, "/NetworkServices/\(identifier)/Interface" as CFString
            ) as? [String: Any] else { return nil }
            guard configuration[kSCPropNetInterfaceType as String] as? String == "VPN" else { continue }
            let provider = configuration[kSCPropNetInterfaceSubType as String] as? String ?? "unknown"
            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID, nil, nil) else { return nil }
            let status = SCNetworkConnectionGetStatus(connection)
            let state: String
            switch status {
            case .connected: state = "connected"
            case .disconnected: state = "disconnected"
            case .connecting: state = "connecting"
            case .disconnecting: state = "disconnecting"
            default: return nil
            }
            var ipv4: String?
            var ipv6: String?
            if status == .connected {
                guard let extended = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else { return nil }
                ipv4 = (extended[kSCEntNetIPv4 as String] as? [String: Any])?[kSCPropInterfaceName as String] as? String
                ipv6 = (extended[kSCEntNetIPv6 as String] as? [String: Any])?[kSCPropInterfaceName as String] as? String
            }
            guard SCNetworkConnectionGetStatus(connection) == status else { return nil }
            observations.append(NetworkServiceObservation(identifier: identifier, provider: provider,
                state: state, ipv4Interface: ipv4, ipv6Interface: ipv6))
        }
        return observations
    }
}
