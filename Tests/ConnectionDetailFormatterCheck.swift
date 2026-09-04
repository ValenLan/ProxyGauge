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
        ) == "其他系统代理已启用", "PAC must show an unattributed system-proxy label.")

        require(detail(
            mode: "系统代理",
            coreHealthy: false,
            entryTitle: "系统代理",
            entryValue: "入口不匹配",
            entryHealthy: false
        ) == "Clash Verge Rev", "The status detail must show the detected client name.")

        require(detail(
            mode: "系统代理",
            entryTitle: "系统代理",
            entryValue: "已启用",
            entryHealthy: true
        ) == "Clash Verge Rev", "A system proxy must keep technical route details out of the status subtitle.")

        require(detail(
            mode: "双重入口",
            entryTitle: "双重入口",
            entryValue: "同时开启",
            entryHealthy: false
        ) == "Clash Verge Rev", "A combined path must show the client name in the subtitle.")

        require(detail(
            mode: "TUN",
            found: false,
            active: false,
            portHealthy: false,
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev", "A TUN-only path must show the client name.")

        require(detail(
            mode: "TUN",
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev", "A confirmed TUN path must keep its endpoint out of the subtitle.")

        require(detail(
            mode: "系统代理路径 + Mihomo TUN",
            entryTitle: "系统代理路径 + Mihomo TUN",
            entryValue: "入口不匹配",
            entryHealthy: false
        ) == "Clash Verge Rev", "A combined path must keep its diagnostic state outside the subtitle.")

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
        ) == "其他 VPN 已连接", "An unidentified virtual adapter must use a neutral connected-VPN label.")

        require(detail(
            client: "未识别",
            mode: "系统代理 + 其他 VPN / TUN",
            found: false,
            active: false,
            coreHealthy: false,
            portHealthy: false,
            entryTitle: "系统代理 + 其他 VPN / TUN",
            entryValue: "同时检测",
            entryHealthy: false
        ) == "其他 VPN / 代理已连接", "An unidentified combined path must use a neutral connected label.")

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
        ) == "未检测到代理客户端", "An inactive route must not fabricate a client.")

        require(detail(
            client: "Clash Verge Rev",
            mode: "未开启",
            found: true,
            active: false,
            coreHealthy: true,
            portHealthy: true,
            entryTitle: "流量入口",
            entryValue: "未启用",
            entryHealthy: false
        ) == "未检测到代理客户端", "A stale client process must not be shown without an active proxy path.")

        print("ProxyGauge connection detail formatter tests passed.")
    }
}
