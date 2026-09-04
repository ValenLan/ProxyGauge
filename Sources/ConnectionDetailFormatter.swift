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
        let knownClient = client != "未识别" && client != "未识别客户端"
        let presentation = ConnectionPathPresentation.make(mode: mode)
        if presentation.isActive {
            if knownClient { return client }
            if presentation.isCombined { return "其他 VPN / 代理已连接" }
            return presentation.hasVirtualAdapter ? "其他 VPN 已连接" : "其他系统代理已启用"
        }
        return "未检测到代理客户端"
    }
}
