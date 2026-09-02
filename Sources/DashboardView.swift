import AppKit
import SwiftUI

struct ContentView: View {
    private static let purityURLs = [
        "https://ippure.com/",
        "https://ipcheck.ing/?hl=zh",
        "https://browserleaks.com/ip",
        "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test"
    ]
    private static let privacyURLs = [
        "https://browserleaks.com/ip",
        "https://browserleaks.com/webrtc",
        "https://www.dnsleaktest.com/",
        "https://test-ipv6.com/"
    ]

    @ObservedObject var model: ProxyModel
    @AppStorage("proxygauge.appearance.v1") private var appearance = "light"
    @State private var browserPrompt: BrowserLaunchPrompt?
    @State private var copiedExitAddress = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    productHeader
                    statusCards
                    currentExitCard
                    browserTools
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 920)
                .frame(
                    maxWidth: .infinity,
                    minHeight: geometry.size.height,
                    alignment: .center
                )
            }
        }
        .frame(
            minWidth: MainWindowLayout.minimumWidth,
            idealWidth: MainWindowLayout.defaultWidth,
            minHeight: MainWindowLayout.minimumContentHeight,
            idealHeight: MainWindowLayout.defaultHeight
        )
        .foregroundStyle(AppThemePalette.text)
        .background(AppThemePalette.canvas)
        .background(MainWindowCapabilityReader().frame(width: 0, height: 0))
        .preferredColorScheme(appearance == "dark" ? .dark : .light)
        .overlay {
            popupLayer
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: popupIdentity)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            model.applicationDidBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            model.applicationDidResignActive()
        }
    }

    private var productHeader: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)

            Text("快速查看代理连接、出口 IP、城市/地区与浏览器隐私状态。")
                .font(CloudTypography.headerDetail)
                .foregroundStyle(AppThemePalette.secondaryText)

            Spacer()

            HeaderUtilityButton(
                symbol: appearance == "dark" ? "moon.fill" : "sun.max.fill",
                help: appearance == "dark" ? "切换到浅色模式" : "切换到深色模式"
            ) {
                appearance = appearance == "dark" ? "light" : "dark"
            }

            HeaderUtilityButton(
                symbol: "arrow.clockwise",
                help: "刷新状态",
                showsProgress: model.isRefreshing
            ) {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing || model.isBusy)
        }
    }

    private var proxyStatusCard: some View {
        Button(action: model.openConnectionSetup) {
            HStack(spacing: 14) {
                CuteDashboardIcon(kind: .proxy, size: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text("代理状态")
                        .font(CloudTypography.metricLabel)
                    HStack(spacing: 8) {
                        Circle().fill(model.overallLevel.color).frame(width: 8, height: 8)
                        Text(model.connectionValue)
                            .font(CloudTypography.metricValue())
                            .foregroundStyle(model.overallLevel.color)
                    }
                    Text(model.connectionDetail)
                        .font(CloudTypography.actionDetail)
                        .foregroundStyle(AppThemePalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppThemePalette.tertiaryText)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        }
        .buttonStyle(DashboardCardButtonStyle())
        .help("打开连接设置")
    }

    private var protectionCard: some View {
        HStack(spacing: 12) {
            CuteDashboardIcon(kind: .protection, size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("断网保护")
                    .font(CloudTypography.metricLabel)
                Text(model.killSwitch.value == "未配置" ? "未开启" : model.killSwitch.value)
                    .font(CloudTypography.metricValue())
                    .foregroundStyle(model.killSwitch.level.color)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { model.killSwitch.level == .ok },
                set: { enabled in
                    if enabled { model.enableKillSwitch() }
                    else { model.showDisableConfirmation = true }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(AppThemePalette.accent)
            .controlSize(.small)
            .disabled(model.isBusy || model.killSwitch.value == "检查中")
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 118)
        .dashboardCard()
    }

    private var currentExitCard: some View {
        HStack(spacing: 16) {
            CuteDashboardIcon(kind: .exit, size: 64)
            VStack(alignment: .leading, spacing: 7) {
                Text("系统实际出口")
                    .font(CloudTypography.metricLabel)
                Text(model.exitAddress)
                    .font(CloudTypography.metricValue(monospaced: true))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ExitChip(model.exitLocation)
                        .layoutPriority(1)
                    if let ipVersion = IPAddressVersion.parse(model.exitAddress) {
                        ExitChip(ipVersion.rawValue)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
        .dashboardCard()
        .help("出口查询遵循 macOS 当前系统网络路径；前台打开时最多每 5 分钟自动核验一次。每次至少由两个独立公网查询服务交叉确认，它们会看到该路径的出口 IP 和请求时间，但不会收到代理配置、订阅或凭据。")
        .overlay(alignment: .topTrailing) {
            HeaderUtilityButton(
                symbol: copiedExitAddress ? "checkmark" : "doc.on.doc",
                help: copiedExitAddress ? "出口 IP 已复制" : "复制出口 IP",
                tint: AppThemePalette.secondaryText
            ) {
                guard PublicIPAddress.normalize(model.exitAddress) == model.exitAddress,
                      ExitClipboard.copy(model.exitAddress) else { return }
                copyFeedbackTask?.cancel()
                copiedExitAddress = true
                copyFeedbackTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(1.5))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    copiedExitAddress = false
                    copyFeedbackTask = nil
                }
            }
            .padding(12)
        }
        .onChange(of: model.exitAddress) {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            copiedExitAddress = false
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
        }
    }

    private var statusCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                proxyStatusCard
                    .frame(minWidth: 340)
                protectionCard
                    .frame(width: 248)
            }

            VStack(spacing: 12) {
                proxyStatusCard
                protectionCard
            }
        }
    }

    private var browserTools: some View {
        AdaptiveToolCardLayout(spacing: 12, horizontalBreakpoint: 650) {
            purityCard
            privacyCard
            speedCard
        }
    }

    private var purityCard: some View {
        BrowserToolCard(
            icon: .purity,
            title: "IP 纯净度",
            detail: "打开第三方 IP 风险检测"
        ) {
            browserPrompt = BrowserLaunchPrompt(
                icon: .purity,
                title: "打开 IP 纯净度检测？",
                detail: "将使用默认浏览器打开 4 个第三方检测页面。ProxyGauge 不会读取或保存页面内容。",
                urls: Self.purityURLs
            )
        }
    }

    private var privacyCard: some View {
        BrowserToolCard(
            icon: .privacy,
            title: "隐私泄露",
            detail: "检查 DNS、WebRTC 与 IPv6"
        ) {
            browserPrompt = BrowserLaunchPrompt(
                icon: .privacy,
                title: "打开隐私泄露检测？",
                detail: "将使用默认浏览器打开 DNS、WebRTC、IPv6 等 4 个检测页面。",
                urls: Self.privacyURLs
            )
        }
    }

    private var speedCard: some View {
        BrowserToolCard(
            icon: .speed,
            title: "浏览器测速",
            detail: "测量真实浏览器路径的延迟与带宽"
        ) {
            browserPrompt = BrowserLaunchPrompt(
                icon: .speed,
                title: "打开浏览器测速？",
                detail: "将使用默认浏览器打开 Cloudflare 测速页面，测量浏览器真实路径。",
                urls: ["https://speed.cloudflare.com/"]
            )
        }
    }

    private func open(_ values: [String]) {
        for value in values {
            guard let url = URL(string: value) else { continue }
            NSWorkspace.shared.open(url)
        }
    }

    private var popupIdentity: String {
        if model.isInstallingUpdate { return "installing" }
        if let browserPrompt { return "browser-\(browserPrompt.id)" }
        if model.showDisableConfirmation { return "disable-protection" }
        if model.showUpdatePrompt { return "update-prompt" }
        if model.showUpdateResult { return "update-result" }
        if let result = model.resultSheet { return "result-\(result.id)" }
        if model.showConnectionSetup { return "connection" }
        return "none"
    }

    @ViewBuilder
    private var popupLayer: some View {
        if model.isInstallingUpdate {
            BubbleOverlay {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.busyLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        } else if let prompt = browserPrompt {
            BubbleOverlay {
                BubblePromptView(
                    icon: prompt.icon,
                    title: prompt.title,
                    detail: prompt.detail,
                    primaryTitle: "继续打开",
                    cancel: { browserPrompt = nil },
                    confirm: {
                        browserPrompt = nil
                        open(prompt.urls)
                    }
                )
            }
        } else if model.showDisableConfirmation {
            BubbleOverlay {
                BubblePromptView(
                    systemSymbol: "shield.slash.fill",
                    tint: .orange,
                    title: "关闭断网保护？",
                    detail: "关闭后，网络路径发生变化时，系统可能通过真实 IP 直接联网。",
                    primaryTitle: "确认关闭",
                    isDestructive: true,
                    cancel: { model.showDisableConfirmation = false },
                    confirm: {
                        model.showDisableConfirmation = false
                        model.disableKillSwitch()
                    }
                )
            }
        } else if model.showUpdatePrompt {
            BubbleOverlay {
                BubblePromptView(
                    systemSymbol: "arrow.down.circle.fill",
                    tint: .blue,
                    title: "发现新版本",
                    detail: "发现 ProxyGauge v\(model.availableUpdate?.version ?? "")。更新包会先通过 SHA-256 校验，再替换当前应用。",
                    primaryTitle: "下载并更新",
                    cancelTitle: "稍后",
                    cancel: { model.showUpdatePrompt = false },
                    confirm: {
                        model.showUpdatePrompt = false
                        model.installAvailableUpdate()
                    }
                )
            }
        } else if model.showUpdateResult {
            BubbleOverlay {
                BubblePromptView(
                    systemSymbol: "info.circle.fill",
                    tint: .blue,
                    title: "软件更新",
                    detail: model.updateMessage,
                    primaryTitle: "知道了",
                    cancelTitle: nil,
                    cancel: {},
                    confirm: { model.showUpdateResult = false }
                )
            }
        } else if let result = model.resultSheet {
            BubbleOverlay {
                ResultView(result: result) { model.resultSheet = nil }
            }
        } else if model.showConnectionSetup {
            BubbleOverlay(dismissOnBackdrop: model.deferConnectionSetup) {
                ConnectionSetupView(
                    discovery: model.discovery,
                    isDiscovering: model.isDiscoveringConnection,
                    confirm: model.confirmConnection,
                    redetect: { Task { await model.discoverConnection() } }
                )
            }
        }
    }
}

private struct BrowserLaunchPrompt: Identifiable {
    let icon: CuteDashboardIcon.Kind
    let title: String
    let detail: String
    let urls: [String]

    var id: String { title }
}

struct BubbleOverlay<Content: View>: View {
    let content: Content
    let dismissOnBackdrop: (() -> Void)?

    init(
        dismissOnBackdrop: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.dismissOnBackdrop = dismissOnBackdrop
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissOnBackdrop?()
                }

            content
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background(AppThemePalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AppThemePalette.border, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
                .padding(22)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }
}

struct BubblePromptView: View {
    private let cuteIcon: CuteDashboardIcon.Kind?
    private let systemSymbol: String?
    private let tint: Color
    let title: String
    let detail: String
    let primaryTitle: String
    var cancelTitle: String? = "取消"
    var isDestructive = false
    let cancel: () -> Void
    let confirm: () -> Void

    init(
        icon: CuteDashboardIcon.Kind,
        title: String,
        detail: String,
        primaryTitle: String,
        cancelTitle: String? = "取消",
        isDestructive: Bool = false,
        cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) {
        cuteIcon = icon
        systemSymbol = nil
        tint = .blue
        self.title = title
        self.detail = detail
        self.primaryTitle = primaryTitle
        self.cancelTitle = cancelTitle
        self.isDestructive = isDestructive
        self.cancel = cancel
        self.confirm = confirm
    }

    init(
        systemSymbol: String,
        tint: Color,
        title: String,
        detail: String,
        primaryTitle: String,
        cancelTitle: String? = "取消",
        isDestructive: Bool = false,
        cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) {
        cuteIcon = nil
        self.systemSymbol = systemSymbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.primaryTitle = primaryTitle
        self.cancelTitle = cancelTitle
        self.isDestructive = isDestructive
        self.cancel = cancel
        self.confirm = confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                if let cuteIcon {
                    CuteDashboardIcon(kind: cuteIcon, size: 52)
                } else if let systemSymbol {
                    ZStack {
                        Circle().fill(tint.opacity(0.11))
                        Image(systemName: systemSymbol)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 52, height: 52)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppThemePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 9) {
                Spacer()
                if let cancelTitle {
                    Button(cancelTitle, action: cancel)
                        .buttonStyle(BubbleActionButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle, action: confirm)
                    .buttonStyle(BubbleActionButtonStyle(isPrimary: true, isDestructive: isDestructive))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 390)
    }
}

private struct BubbleActionButtonStyle: ButtonStyle {
    var isPrimary = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(
                isPrimary
                    ? (isDestructive ? Color.white : AppThemePalette.onAccent)
                    : AppThemePalette.text
            )
            .padding(.horizontal, 15)
            .frame(minWidth: 78, minHeight: 32)
            .background(
                isPrimary
                    ? (isDestructive ? Color.orange : AppThemePalette.accent).opacity(configuration.isPressed ? 0.72 : 1)
                    : AppThemePalette.raisedSurface.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppThemePalette.border, lineWidth: 1)
                }
            }
    }
}

private struct HeaderUtilityButton: View {
    let symbol: String
    let help: String
    var tint = AppThemePalette.accent
    var showsProgress = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .tint(tint)
            .frame(width: 18, height: 18)
            .padding(8)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct BrowserToolCard: View {
    let icon: CuteDashboardIcon.Kind
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CuteDashboardIcon(kind: icon, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(CloudTypography.actionTitle)
                    Text(detail)
                        .font(CloudTypography.actionDetail)
                        .foregroundStyle(AppThemePalette.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppThemePalette.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        }
        .buttonStyle(DashboardCardButtonStyle())
    }
}

private struct AdaptiveToolCardLayout: Layout {
    let spacing: CGFloat
    let horizontalBreakpoint: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? horizontalBreakpoint
        guard !subviews.isEmpty else { return CGSize(width: availableWidth, height: 0) }

        if availableWidth >= horizontalBreakpoint {
            let itemWidth = (availableWidth - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
            let height = subviews
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }
                .max() ?? 0
            return CGSize(width: availableWidth, height: height)
        }

        let heights = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil)).height
        }
        return CGSize(
            width: availableWidth,
            height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        if bounds.width >= horizontalBreakpoint {
            let itemWidth = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(x: bounds.minX + CGFloat(index) * (itemWidth + spacing), y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: bounds.height)
                )
            }
            return
        }

        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: size.height)
            )
            y += size.height + spacing
        }
    }
}

private struct DashboardCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? AppThemePalette.raisedSurface
                    : AppThemePalette.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(configuration.isPressed ? AppThemePalette.accent.opacity(0.72) : AppThemePalette.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension View {
    func dashboardCard() -> some View {
        background(AppThemePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppThemePalette.border, lineWidth: 1)
            }
    }
}

private struct ExitChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(AppThemePalette.accent)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(AppThemePalette.accent.opacity(0.12), in: Capsule())
    }
}

struct CuteDashboardIcon: View {
    enum Kind { case proxy, exit, purity, privacy, speed, protection }
    let kind: Kind
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.blue.opacity(0.09))
            CuteGlyph(kind: kind)
                .frame(width: size * 0.64, height: size * 0.64)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CuteGlyph: View {
    let kind: CuteDashboardIcon.Kind

    private let line = StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 48, y: size.height / 48)
            context.fill(Self.outer(kind), with: .color(Color.blue.opacity(0.20)))
            context.stroke(Self.outer(kind), with: .color(.blue), style: line)
            for path in Self.lines(kind) {
                context.stroke(path, with: .color(.blue), style: line)
            }
            for path in Self.chunks(kind) {
                context.fill(path, with: .color(.blue))
            }
        }
    }

    private static func outer(_ kind: CuteDashboardIcon.Kind) -> Path {
        switch kind {
        case .proxy:
            return Path { p in
                p.move(to: CGPoint(x: 14.3, y: 10.8))
                p.addCurve(to: CGPoint(x: 9.2, y: 16.4), control1: CGPoint(x: 11.2, y: 11.2), control2: CGPoint(x: 9.2, y: 13.4))
                p.addLine(to: CGPoint(x: 9.2, y: 31.6))
                p.addCurve(to: CGPoint(x: 15, y: 37.3), control1: CGPoint(x: 9.2, y: 35.1), control2: CGPoint(x: 11.4, y: 37.3))
                p.addLine(to: CGPoint(x: 33, y: 37.3))
                p.addCurve(to: CGPoint(x: 38.8, y: 31.6), control1: CGPoint(x: 36.6, y: 37.3), control2: CGPoint(x: 38.8, y: 35.1))
                p.addLine(to: CGPoint(x: 38.8, y: 16.4))
                p.addCurve(to: CGPoint(x: 32.9, y: 10.8), control1: CGPoint(x: 38.8, y: 13), control2: CGPoint(x: 36.4, y: 10.8))
                p.closeSubpath()
            }
        case .exit:
            return Path { p in
                p.move(to: CGPoint(x: 24.8, y: 5.1))
                p.addCurve(to: CGPoint(x: 5.1, y: 24.4), control1: CGPoint(x: 13.2, y: 4.8), control2: CGPoint(x: 5.3, y: 12.8))
                p.addCurve(to: CGPoint(x: 23.7, y: 43.1), control1: CGPoint(x: 4.9, y: 35.5), control2: CGPoint(x: 12.5, y: 43))
                p.addCurve(to: CGPoint(x: 42.9, y: 23.9), control1: CGPoint(x: 35.2, y: 43.2), control2: CGPoint(x: 42.9, y: 35.4))
                p.addCurve(to: CGPoint(x: 24.8, y: 5.1), control1: CGPoint(x: 42.9, y: 12.9), control2: CGPoint(x: 35.5, y: 5.4))
                p.closeSubpath()
            }
        case .purity:
            return Path { p in
                p.move(to: CGPoint(x: 22.2, y: 6.5))
                p.addCurve(to: CGPoint(x: 6.5, y: 21.8), control1: CGPoint(x: 12.9, y: 6.3), control2: CGPoint(x: 6.7, y: 12.4))
                p.addCurve(to: CGPoint(x: 21.6, y: 37.1), control1: CGPoint(x: 6.3, y: 31), control2: CGPoint(x: 12.5, y: 37))
                p.addCurve(to: CGPoint(x: 31.6, y: 33.8), control1: CGPoint(x: 25.6, y: 37.1), control2: CGPoint(x: 29, y: 36))
                p.addLine(to: CGPoint(x: 39.7, y: 41.9))
                p.addCurve(to: CGPoint(x: 44.5, y: 42), control1: CGPoint(x: 41.1, y: 43.3), control2: CGPoint(x: 43.2, y: 43.3))
                p.addCurve(to: CGPoint(x: 44.4, y: 37.2), control1: CGPoint(x: 45.8, y: 40.6), control2: CGPoint(x: 45.8, y: 38.5))
                p.addLine(to: CGPoint(x: 36.2, y: 29.4))
                p.addCurve(to: CGPoint(x: 38.3, y: 21.5), control1: CGPoint(x: 37.6, y: 27.1), control2: CGPoint(x: 38.3, y: 24.5))
                p.addCurve(to: CGPoint(x: 22.2, y: 6.5), control1: CGPoint(x: 38.3, y: 12.5), control2: CGPoint(x: 31.9, y: 6.7))
                p.closeSubpath()
            }
        case .privacy:
            return Path { p in
                p.move(to: CGPoint(x: 4.5, y: 24.5))
                p.addCurve(to: CGPoint(x: 24.1, y: 12), control1: CGPoint(x: 8.7, y: 16.1), control2: CGPoint(x: 15.1, y: 12))
                p.addCurve(to: CGPoint(x: 43.5, y: 24.3), control1: CGPoint(x: 32.9, y: 12), control2: CGPoint(x: 39.5, y: 16.1))
                p.addCurve(to: CGPoint(x: 24.2, y: 36), control1: CGPoint(x: 39.2, y: 32), control2: CGPoint(x: 32.8, y: 36))
                p.addCurve(to: CGPoint(x: 4.5, y: 24.5), control1: CGPoint(x: 15.5, y: 36), control2: CGPoint(x: 8.9, y: 32.1))
                p.closeSubpath()
            }
        case .speed:
            return Path { p in
                p.move(to: CGPoint(x: 6.2, y: 36.4))
                p.addCurve(to: CGPoint(x: 5.1, y: 27.9), control1: CGPoint(x: 5.2, y: 33.4), control2: CGPoint(x: 4.8, y: 30.9))
                p.addCurve(to: CGPoint(x: 24.6, y: 10.2), control1: CGPoint(x: 6.1, y: 17.3), control2: CGPoint(x: 14.3, y: 10))
                p.addCurve(to: CGPoint(x: 42.9, y: 29), control1: CGPoint(x: 34.9, y: 10.4), control2: CGPoint(x: 42.9, y: 18.3))
                p.addCurve(to: CGPoint(x: 41.4, y: 36.4), control1: CGPoint(x: 42.9, y: 31.7), control2: CGPoint(x: 42.4, y: 34.2))
                p.addCurve(to: CGPoint(x: 6.2, y: 36.4), control1: CGPoint(x: 32.9, y: 39.8), control2: CGPoint(x: 14.6, y: 39.9))
                p.closeSubpath()
            }
        case .protection:
            return Path { p in
                p.move(to: CGPoint(x: 24, y: 4.9))
                p.addCurve(to: CGPoint(x: 41, y: 11.7), control1: CGPoint(x: 29.5, y: 8.5), control2: CGPoint(x: 34.3, y: 10.3))
                p.addLine(to: CGPoint(x: 41, y: 23.2))
                p.addCurve(to: CGPoint(x: 24, y: 43.2), control1: CGPoint(x: 41, y: 33.6), control2: CGPoint(x: 35.3, y: 40.2))
                p.addCurve(to: CGPoint(x: 7, y: 23.2), control1: CGPoint(x: 12.8, y: 40.1), control2: CGPoint(x: 7, y: 33.5))
                p.addLine(to: CGPoint(x: 7, y: 11.7))
                p.addCurve(to: CGPoint(x: 24, y: 4.9), control1: CGPoint(x: 13.6, y: 10.3), control2: CGPoint(x: 18.4, y: 8.5))
                p.closeSubpath()
            }
        }
    }

    private static func lines(_ kind: CuteDashboardIcon.Kind) -> [Path] {
        switch kind {
        case .proxy:
            return [Path { p in
                for (a, b) in [
                    (CGPoint(x: 16, y: 5.8), CGPoint(x: 16, y: 10.8)),
                    (CGPoint(x: 24, y: 4.6), CGPoint(x: 24, y: 10.8)),
                    (CGPoint(x: 32, y: 5.8), CGPoint(x: 32, y: 10.8)),
                    (CGPoint(x: 16, y: 37.3), CGPoint(x: 16, y: 42.2)),
                    (CGPoint(x: 24, y: 37.3), CGPoint(x: 24, y: 43.3)),
                    (CGPoint(x: 32, y: 37.3), CGPoint(x: 32, y: 42.2)),
                    (CGPoint(x: 4.7, y: 18), CGPoint(x: 9.2, y: 18)),
                    (CGPoint(x: 3.6, y: 25.2), CGPoint(x: 9.2, y: 25.2)),
                    (CGPoint(x: 4.7, y: 32.4), CGPoint(x: 9.2, y: 32.4)),
                    (CGPoint(x: 38.8, y: 17.7), CGPoint(x: 43.3, y: 17.7)),
                    (CGPoint(x: 38.8, y: 25.2), CGPoint(x: 44.4, y: 25.2)),
                    (CGPoint(x: 38.8, y: 32.4), CGPoint(x: 43.3, y: 32.4))
                ] { p.move(to: a); p.addLine(to: b) }
                p.move(to: CGPoint(x: 20, y: 24.2)); p.addLine(to: CGPoint(x: 28, y: 24.2))
            }]
        case .exit:
            return [Path { p in
                p.move(to: CGPoint(x: 6.1, y: 23.2)); p.addCurve(to: CGPoint(x: 41.9, y: 23.1), control1: CGPoint(x: 14.5, y: 25.1), control2: CGPoint(x: 33.8, y: 25.6))
                p.move(to: CGPoint(x: 10.2, y: 13.7)); p.addCurve(to: CGPoint(x: 37.6, y: 13.6), control1: CGPoint(x: 16.7, y: 16.2), control2: CGPoint(x: 30.8, y: 16.2))
                p.move(to: CGPoint(x: 10.2, y: 34.4)); p.addCurve(to: CGPoint(x: 37.9, y: 34.5), control1: CGPoint(x: 16.9, y: 32.2), control2: CGPoint(x: 31.4, y: 32.2))
                p.move(to: CGPoint(x: 23.2, y: 5.6)); p.addCurve(to: CGPoint(x: 23.8, y: 42.3), control1: CGPoint(x: 14.4, y: 16.2), control2: CGPoint(x: 16.1, y: 33.8))
                p.move(to: CGPoint(x: 25.8, y: 5.7)); p.addCurve(to: CGPoint(x: 24.7, y: 42.3), control1: CGPoint(x: 33.8, y: 16.7), control2: CGPoint(x: 31.5, y: 33.5))
            }]
        case .purity:
            return [Path(ellipseIn: CGRect(x: 14.8, y: 14.5, width: 14.8, height: 14.8)), Path { p in
                p.move(to: CGPoint(x: 22.2, y: 10.9)); p.addLine(to: CGPoint(x: 22.2, y: 15))
                p.move(to: CGPoint(x: 22.2, y: 28.8)); p.addLine(to: CGPoint(x: 22.2, y: 32.9))
                p.move(to: CGPoint(x: 11.2, y: 21.9)); p.addLine(to: CGPoint(x: 15.3, y: 21.9))
                p.move(to: CGPoint(x: 29.1, y: 21.9)); p.addLine(to: CGPoint(x: 33.2, y: 21.9))
            }]
        case .privacy:
            return [Path { p in
                p.move(to: CGPoint(x: 8.3, y: 8.2)); p.addLine(to: CGPoint(x: 39.8, y: 40))
            }]
        case .speed:
            return [Path { p in
                p.move(to: CGPoint(x: 11.1, y: 27.6)); p.addLine(to: CGPoint(x: 8.2, y: 27))
                p.move(to: CGPoint(x: 16.3, y: 19.8)); p.addLine(to: CGPoint(x: 14.1, y: 17.5))
                p.move(to: CGPoint(x: 24.6, y: 16.6)); p.addLine(to: CGPoint(x: 24.6, y: 13.6))
                p.move(to: CGPoint(x: 32.8, y: 20.4)); p.addLine(to: CGPoint(x: 35.1, y: 18.3))
                p.move(to: CGPoint(x: 36.8, y: 28.1)); p.addLine(to: CGPoint(x: 39.8, y: 27.6))
            }]
        case .protection:
            return [Path { p in
                p.move(to: CGPoint(x: 15.2, y: 24.2)); p.addLine(to: CGPoint(x: 21.2, y: 30.3)); p.addLine(to: CGPoint(x: 33.4, y: 17.3))
            }]
        }
    }

    private static func chunks(_ kind: CuteDashboardIcon.Kind) -> [Path] {
        switch kind {
        case .proxy:
            return [Path(roundedRect: CGRect(x: 14.4, y: 17.2, width: 19.1, height: 13.7), cornerRadius: 3.3)]
        case .purity:
            return [Path(ellipseIn: CGRect(x: 19.7, y: 19.4, width: 5, height: 5))]
        case .privacy:
            return [Path(ellipseIn: CGRect(x: 16.8, y: 17.2, width: 14.7, height: 14))]
        case .speed:
            return [Path { p in
                p.move(to: CGPoint(x: 21.6, y: 31.5)); p.addCurve(to: CGPoint(x: 21.4, y: 26.3), control1: CGPoint(x: 20, y: 30), control2: CGPoint(x: 19.9, y: 27.8)); p.addLine(to: CGPoint(x: 31.6, y: 18.8)); p.addLine(to: CGPoint(x: 24.8, y: 30.4)); p.addCurve(to: CGPoint(x: 21.6, y: 31.5), control1: CGPoint(x: 24, y: 32.1), control2: CGPoint(x: 22.8, y: 32.4)); p.closeSubpath()
            }, Path(ellipseIn: CGRect(x: 20.2, y: 25.7, width: 6.6, height: 6.6))]
        case .exit, .protection:
            return []
        }
    }
}
