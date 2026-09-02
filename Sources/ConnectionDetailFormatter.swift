import Foundation

enum ConnectionDetailFormatter {
    static func format(
        client: String,
        endpoint: String,
        mode: String,
        discoveryFound: Bool,
        discoveryActive: Bool,
        coreHealthy: Bool,
        portHealthy: Bool,
        entryTitle: String,
        entryValue: String,
        entryHealthy: Bool
    ) -> String {
        if mode.contains("其他 VPN / TUN") {
            return mode.contains("系统代理")
                ? "其他 VPN / TUN · 与系统代理并存"
                : "其他 VPN / TUN · 系统路径"
        }

        let attributableModes = ["系统代理", "TUN", "双重入口"]
        let knownClient = client != "未识别" && client != "未识别客户端"
        let confirmedTunPath = mode == "TUN"
            && coreHealthy
            && entryTitle == "TUN 路由"
            && entryValue == "代表性路由已确认"
            && entryHealthy
            && knownClient
        if confirmedTunPath {
            if discoveryFound && discoveryActive && portHealthy {
                return "\(client) · TUN · \(endpoint)"
            }
            return "\(client) · TUN"
        }

        let confirmedDualEntry = mode == "双重入口"
            && entryTitle == "双重入口"
            && entryValue == "同时开启"
        let confirmedMihomoPath = attributableModes.contains(mode)
            && discoveryFound
            && discoveryActive
            && coreHealthy
            && portHealthy
            && knownClient
            && (entryHealthy || confirmedDualEntry)
        if confirmedMihomoPath {
            return "\(client) · \(mode) · \(endpoint)"
        }

        if mode == "未开启" {
            return "系统路径 · 未检测到代理入口"
        }
        if mode == "PAC / 自动代理" {
            return "系统路径 · PAC / 自动代理"
        }

        let route = switch entryTitle {
        case "TUN 路由": "TUN"
        case "双重入口": "系统代理 + TUN"
        case "流量入口" where mode != "状态不可用": mode
        default: entryTitle
        }
        let meaningfulValue = !entryValue.isEmpty
            && !["检查中", "已启用", "已接管", "同时开启", "代表性路由已确认"].contains(entryValue)
        return meaningfulValue
            ? "系统路径 · \(route) · \(entryValue)"
            : "系统路径 · \(route)"
    }
}
