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
        core: String = "verge-mihomo",
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
            core: core,
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
            core: "",
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
        ) == "Clash Verge Rev · verge-mihomo", "The status detail must show the client and core names.")

        require(detail(
            mode: "系统代理",
            entryTitle: "系统代理",
            entryValue: "已启用",
            entryHealthy: true
        ) == "Clash Verge Rev · verge-mihomo", "A system proxy must show the client and core names.")

        require(detail(
            mode: "双重入口",
            entryTitle: "双重入口",
            entryValue: "同时开启",
            entryHealthy: false
        ) == "Clash Verge Rev · verge-mihomo", "A combined path must show the client and core names in the subtitle.")

        require(detail(
            mode: "TUN",
            found: false,
            active: false,
            portHealthy: false,
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev · verge-mihomo", "A TUN-only path must show the client and core names.")

        require(detail(
            mode: "TUN",
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Clash Verge Rev · verge-mihomo", "A confirmed TUN path must show the client and core without the endpoint.")

        require(detail(
            mode: "系统代理路径 + Mihomo TUN",
            entryTitle: "系统代理路径 + Mihomo TUN",
            entryValue: "入口不匹配",
            entryHealthy: false
        ) == "Clash Verge Rev · verge-mihomo", "A combined path must show the client and core without diagnostics.")

        require(detail(
            client: "未识别",
            core: "",
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
            core: "",
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
            core: "",
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
            core: "verge-mihomo",
            mode: "未开启",
            found: true,
            active: false,
            coreHealthy: true,
            portHealthy: true,
            entryTitle: "流量入口",
            entryValue: "未启用",
            entryHealthy: false
        ) == "未检测到代理客户端", "A stale client process must not be shown without an active proxy path.")

        require(detail(
            client: "Shadowrocket",
            core: "MacPacketTunnel",
            endpoint: "127.0.0.1:1082",
            mode: "Shadowrocket VPN",
            entryTitle: "Shadowrocket VPN",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Shadowrocket · MacPacketTunnel", "A detected Shadowrocket packet-tunnel engine must retain its actual process name.")

        require(detail(
            client: "Shadowrocket",
            core: "MacPacketTunnel",
            endpoint: "127.0.0.1:1082",
            mode: "系统代理 + Shadowrocket VPN",
            entryTitle: "双重入口",
            entryValue: "同时开启",
            entryHealthy: false
        ) == "Shadowrocket · MacPacketTunnel", "A combined Shadowrocket path must retain its detected packet-tunnel engine.")

        require(detail(
            client: "Shadowrocket",
            core: "Shadowrocket",
            mode: "系统代理",
            entryTitle: "系统代理",
            entryValue: "已启用",
            entryHealthy: true
        ) == "Shadowrocket", "A running Shadowrocket GUI must not fabricate a MacPacketTunnel process.")

        require(detail(
            client: "Shadowrocket",
            core: "sing-box",
            mode: "系统代理 + 其他 VPN / TUN",
            entryTitle: "系统代理 + 其他 VPN / TUN",
            entryValue: "同时检测",
            entryHealthy: false
        ) == "Shadowrocket · sing-box", "The client label must not rewrite another observed core process as MacPacketTunnel.")

        require(detail(
            client: "Shadowrocket",
            core: "",
            endpoint: "127.0.0.1:1082",
            mode: "Shadowrocket VPN",
            entryTitle: "Shadowrocket VPN",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Shadowrocket", "A Shadowrocket path without an engine must keep the client name.")

        require(detail(
            client: "Shadowrocket",
            core: "未识别",
            mode: "Shadowrocket VPN",
            entryTitle: "Shadowrocket VPN",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "Shadowrocket", "An unknown engine must not be fabricated as MacPacketTunnel.")

        // Current path attribution is independent of listener/health diagnostics.
        for mode in ["系统代理", "Shadowrocket VPN", "系统代理 + Shadowrocket VPN"] {
            for unknownClient in ["未识别", "未识别客户端"] {
                require(detail(
                    client: unknownClient,
                    core: "MacPacketTunnel",
                    mode: mode,
                    found: false,
                    active: false,
                    coreHealthy: false,
                    portHealthy: false,
                    entryTitle: "流量入口",
                    entryValue: "状态不可用",
                    entryHealthy: false
                ) == "MacPacketTunnel", "Only a known core must be shown when the client is unknown: \(mode).")
            }
            require(detail(
                client: "Shadowrocket",
                core: "MacPacketTunnel",
                mode: mode,
                found: false,
                active: false,
                coreHealthy: false,
                portHealthy: false,
                entryTitle: "流量入口",
                entryValue: "状态不可用",
                entryHealthy: false
            ) == "Shadowrocket · MacPacketTunnel", "Failed health diagnostics must not rewrite current path attribution: \(mode).")
        }
        require(detail(
            client: "SING-BOX",
            core: "sing-box",
            mode: "TUN",
            entryTitle: "TUN 路由",
            entryValue: "代表性路由已确认",
            entryHealthy: true
        ) == "sing-box", "Case-equivalent client and core names must show the actual core only once.")

        print("ProxyGauge connection detail formatter tests passed.")
    }
}
