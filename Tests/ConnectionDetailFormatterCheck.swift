import Foundation

@main
struct ConnectionDetailFormatterCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    static func detail(
        client: String = "Clash Verge Rev",
        endpoint: String = "127.0.0.1:7890",
        mode: String,
        found: Bool = true,
        active: Bool = true,
        coreHealthy: Bool = true,
        portHealthy: Bool = true,
        entryTitle: String,
        entryValue: String,
        entryHealthy: Bool
    ) -> String {
        ConnectionDetailFormatter.format(
            client: client,
            endpoint: endpoint,
            mode: mode,
            discoveryFound: found,
            discoveryActive: active,
            coreHealthy: coreHealthy,
            portHealthy: portHealthy,
            entryTitle: entryTitle,
            entryValue: entryValue,
            entryHealthy: entryHealthy
        )
    }

    static func main() {
        require(detail(
            client: "未识别",
            mode: "PAC / 自动代理",
            found: false,
            active: false,
            coreHealthy: false,
            portHealthy: false,
            entryTitle: "PAC / 自动代理",
            entryValue: "按目标动态决定",
            entryHealthy: false
        ) == "系统路径 · PAC / 自动代理", "PAC must not display a fabricated Mihomo endpoint.")

        require(detail(
            mode: "系统代理",
            coreHealthy: false,
            entryTitle: "系统代理",
            entryValue: "入口不匹配",
            entryHealthy: false
        ) == "系统路径 · 系统代理 · 入口不匹配", "A mismatched proxy must remain a system path.")

        require(detail(
            mode: "系统代理",
            entryTitle: "系统代理",
            entryValue: "已启用",
            entryHealthy: true
        ) == "Clash Verge Rev · 系统代理 · 127.0.0.1:7890", "A fully verified Mihomo route may show its endpoint.")

        require(detail(
            mode: "双重入口",
            entryTitle: "双重入口",
            entryValue: "同时开启",
            entryHealthy: false
        ) == "Clash Verge Rev · 双重入口 · 127.0.0.1:7890", "A fully verified dual route may show its endpoint.")

        require(detail(
            mode: "TUN",
            found: false,
            active: false,
            portHealthy: false,
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev · TUN", "A confirmed TUN-only path must not depend on or fabricate a mixed-port endpoint.")

        require(detail(
            mode: "TUN",
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev · TUN · 127.0.0.1:7890", "A confirmed TUN path may include a separately verified local listener.")

        require(detail(
            mode: "系统代理路径 + Mihomo TUN",
            entryTitle: "系统代理路径 + Mihomo TUN",
            entryValue: "入口不匹配",
            entryHealthy: false
        ) == "系统路径 · 系统代理路径 + Mihomo TUN · 入口不匹配", "An uncertain system half of a TUN combination must not show an endpoint.")

        require(detail(
            client: "未识别",
            mode: "其他 VPN / TUN",
            found: false,
            active: false,
            coreHealthy: false,
            portHealthy: false,
            entryTitle: "其他 VPN / TUN",
            entryValue: "已检测",
            entryHealthy: false
        ) == "其他 VPN / TUN · 系统路径", "Another VPN must not be attributed to Mihomo.")

        require(detail(
            client: "未识别",
            mode: "未开启",
            found: false,
            active: false,
            coreHealthy: false,
            portHealthy: false,
            entryTitle: "流量入口",
            entryValue: "未启用",
            entryHealthy: false
        ) == "系统路径 · 未检测到代理入口", "An inactive route must not show the default port as active evidence.")

        print("ProxyGauge connection detail formatter tests passed.")
    }
}
