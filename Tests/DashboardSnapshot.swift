#if SNAPSHOT
import AppKit
import SwiftUI

@main
struct DashboardSnapshot {
    @MainActor
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw SnapshotError.missingOutput
        }

        let snapshotState = CommandLine.arguments.count == 3
            ? CommandLine.arguments[2]
            : "dashboard"
        let isDark = snapshotState.hasSuffix("-dark")
        let layoutState = snapshotState.replacingOccurrences(of: "-dark", with: "")
        let renderSize: CGSize = switch layoutState {
        case "dashboard-compact": CGSize(width: 760, height: 500)
        case "dashboard-wide": CGSize(width: 1000, height: 500)
        case "dashboard-fullscreen": CGSize(width: 1440, height: 900)
        default: CGSize(width: 820, height: 500)
        }
        UserDefaults.standard.set(isDark ? "dark" : "light", forKey: "proxygauge.appearance.v1")
        if let icon = NSImage(contentsOfFile: "Resources/ProxyGauge.icns") {
            NSApplication.shared.applicationIconImage = icon
        }

        let model = ProxyModel(startImmediately: false)
        model.overallLevel = .ok
        model.headline = "代理已连接"
        model.detail = "Mihomo · TUN · 127.0.0.1:7890"
        model.discovery = ProxyDiscovery(
            found: true,
            client: "Mihomo",
            endpoint: "127.0.0.1:7890",
            mode: "TUN",
            source: "Mihomo 控制接口",
            active: true
        )
        model.killSwitch = MetricState(
            title: "断网保护",
            symbol: "shield",
            value: "已开启",
            level: .ok
        )
        model.exitAddress = snapshotState.hasPrefix("dashboard-ipv6")
            ? "2001:db8:85a3::8a2e:370:7334"
            : "198.51.100.24"
        model.exitLocation = "美国 · 洛杉矶"
        model.showGuardApplicationSelection = snapshotState.hasPrefix("guard-selection")
        if model.showGuardApplicationSelection {
            model.guardApplications = [
                .init(path: "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo", uid: 0),
                .init(path: "/Applications/iKuuu VPN.app/Contents/MacOS/iKuuuVPNCore", uid: 0)
            ]
        }
        model.showConnectionSetup = snapshotState.hasPrefix("connection-setup")

        let dashboard = ContentView(model: model)
            .frame(width: renderSize.width, height: renderSize.height)
            .environment(\.colorScheme, isDark ? .dark : .light)
        let view: AnyView
        if snapshotState.hasPrefix("browser-prompt") {
            view = AnyView(
                dashboard.overlay {
                    BubbleOverlay {
                        BubblePromptView(
                            icon: .purity,
                            title: "打开 IP 纯净度检测？",
                            detail: "将使用默认浏览器打开 4 个第三方检测页面。ProxyGauge 不会读取或保存页面内容。",
                            primaryTitle: "继续打开",
                            cancel: {},
                            confirm: {}
                        )
                    }
                }
            )
        } else {
            view = AnyView(dashboard)
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: renderSize)
        hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = isDark ? .windowBackgroundColor : .white
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }

    private enum SnapshotError: Error {
        case missingOutput
        case renderFailed
    }
}
#endif
