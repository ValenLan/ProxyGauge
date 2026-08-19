import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum HealthLevel: String, Sendable {
    case ok
    case warning
    case error
    case idle

    var color: Color {
        switch self {
        case .ok: return CloudPalette.statusGreen
        case .warning: return CloudPalette.statusOrange
        case .error: return CloudPalette.statusRed
        case .idle: return CloudPalette.statusGray
        }
    }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "circle.fill"
        }
    }
}

struct MetricState: Sendable {
    var title: String
    var symbol: String
    var value: String
    var level: HealthLevel
}

enum ResultKind {
    case health
    case standard
}

struct ResultSheet: Identifiable {
    let id = UUID()
    let kind: ResultKind
    let title: String
    let output: String
    let success: Bool
}

struct ProxyDiscovery: Sendable, Equatable {
    var found = false
    var client = "正在检测"
    var endpoint = "127.0.0.1:7890"
    var mode = "正在读取"
    var source = "本地运行状态"
    var active = false
    var privacy = "仅读取本地端口与运行模式，不读取订阅和节点"
}

private enum CloudRoutePreferences {
    static let setupCompletedKey = "cloudroute.connectionSetupCompleted.v1"
    static let selectedEndpointKey = "cloudroute.selectedMixedEndpoint"

    static func validLocalEndpoint(_ endpoint: String) -> Bool {
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              ["127.0.0.1", "localhost"].contains(String(parts[0])),
              let port = Int(parts[1]),
              (1...65535).contains(port) else { return false }
        return true
    }
}

@MainActor
final class ProxyModel: ObservableObject {
    @Published var headline = "正在读取状态"
    @Published var detail = "检查代理核心与流量入口…"
    @Published var overallLevel: HealthLevel = .idle
    @Published var isRefreshing = false
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var resultSheet: ResultSheet?
    @Published var showDisableConfirmation = false
    @Published var showConnectionSetup = false
    @Published var isDiscoveringConnection = false
    @Published var discovery = ProxyDiscovery()

    @Published var core = MetricState(title: "代理核心", symbol: "cpu", value: "检查中", level: .idle)
    @Published var port = MetricState(title: "本地端口", symbol: "network", value: "检查中", level: .idle)
    @Published var entry = MetricState(title: "流量入口", symbol: "arrow.triangle.branch", value: "检查中", level: .idle)
    @Published var killSwitch = MetricState(title: "Kill Switch", symbol: "shield.fill", value: "未确认", level: .idle)

    private let backendPath = Bundle.main.path(forResource: "cloudroute-backend", ofType: "sh")
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/cloudroute/cloudroute-backend.sh").path
    init() {
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            if !UserDefaults.standard.bool(forKey: CloudRoutePreferences.setupCompletedKey) {
                await self.discoverConnection(showSheet: true)
            }
        }
    }

    func openConnectionSetup() {
        Task { [weak self] in
            await self?.discoverConnection(showSheet: true)
        }
    }

    func discoverConnection(showSheet: Bool = false) async {
        guard !isDiscoveringConnection else { return }
        isDiscoveringConnection = true
        if showSheet {
            showConnectionSetup = true
        }

        let result = await execute("discover")
        if result.status == 0 {
            discovery = parseDiscovery(result.output)
        } else {
            discovery = ProxyDiscovery(
                found: false,
                client: "未发现代理客户端",
                endpoint: "127.0.0.1:7890",
                mode: "未开启",
                source: "请手动设置",
                active: false
            )
        }
        isDiscoveringConnection = false
    }

    func confirmConnection(endpoint: String) {
        guard CloudRoutePreferences.validLocalEndpoint(endpoint) else { return }
        UserDefaults.standard.set(endpoint, forKey: CloudRoutePreferences.selectedEndpointKey)
        UserDefaults.standard.set(true, forKey: CloudRoutePreferences.setupCompletedKey)
        showConnectionSetup = false
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func deferConnectionSetup() {
        showConnectionSetup = false
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let result = await execute("probe")
        isRefreshing = false

        guard result.status == 0 else {
            headline = "无法读取状态"
            detail = result.output.isEmpty ? "后端脚本未响应" : result.output
            overallLevel = .error
            return
        }
        applyProbe(result.output)
    }

    func runHealthCheck() {
        runAction("health", title: "代理健康检查", busy: "正在全面检查代理…")
    }

    func enableKillSwitch() {
        runAction("kill-on", title: "已开启 Kill Switch", busy: "正在开启 Kill Switch…")
    }

    func disableKillSwitch() {
        runAction("kill-off", title: "已关闭 Kill Switch", busy: "正在关闭 Kill Switch…")
    }

    private func runAction(_ action: String, title: String, busy: String) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = busy

        Task { [weak self] in
            guard let self else { return }
            let result = await self.execute(action)
            let cleanOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHealth = action == "health"
            let succeeded = result.status == 0 && (!isHealth || !cleanOutput.isEmpty)
            let displayedOutput: String
            if isHealth && cleanOutput.isEmpty {
                displayedOutput = """
                ===== 1. 健康检查脚本 =====
                  ❌ 脚本没有返回文本（退出状态 \(result.status)）
                  ℹ️ 请确认 App 内置脚本可执行，然后重新运行健康检查
                """
            } else if cleanOutput.isEmpty {
                displayedOutput = succeeded ? "操作已完成。" : "没有收到操作结果。"
            } else {
                displayedOutput = cleanOutput
            }
            self.isBusy = false
            self.busyLabel = ""
            self.resultSheet = ResultSheet(
                kind: isHealth ? .health : .standard,
                title: isHealth ? title : (succeeded ? title : "操作失败"),
                output: displayedOutput,
                success: succeeded
            )
            await self.refresh()
        }
    }

    private func applyProbe(_ output: String) {
        var parsed: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let key = fields.first else { continue }
            parsed[key] = Array(fields.dropFirst())
        }

        overallLevel = HealthLevel(rawValue: parsed["overall"]?.first ?? "") ?? .idle
        headline = parsed["headline"]?.first ?? "状态未知"
        detail = parsed["detail"]?.first ?? "请刷新后重试"
        updateMetric(&core, from: parsed["core"])
        updateMetric(&port, from: parsed["port"])
        updateMetric(&entry, from: parsed["entry"] ?? parsed["tun"])
        updateMetric(&killSwitch, from: parsed["kill"])
    }

    private func parseDiscovery(_ output: String) -> ProxyDiscovery {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }

        let endpoint = fields["endpoint"] ?? "127.0.0.1:7890"
        return ProxyDiscovery(
            found: fields["found"] == "1" && CloudRoutePreferences.validLocalEndpoint(endpoint),
            client: fields["client"] ?? "未识别",
            endpoint: endpoint,
            mode: fields["mode"] ?? "未开启",
            source: fields["source"] ?? "手动设置",
            active: fields["active"] == "ok",
            privacy: fields["privacy"] ?? "仅读取本地端口与运行模式，不读取订阅和节点"
        )
    }

    private func updateMetric(_ metric: inout MetricState, from fields: [String]?) {
        guard let fields, fields.count >= 2 else { return }
        metric.value = fields[0]
        metric.level = HealthLevel(rawValue: fields[1]) ?? .idle
        if fields.count >= 4 {
            metric.title = fields[2]
            metric.symbol = fields[3]
        }
    }

    private func execute(_ action: String) async -> (status: Int32, output: String) {
        let path = backendPath
        let selectedEndpoint = UserDefaults.standard.string(forKey: CloudRoutePreferences.selectedEndpointKey)
        let validSelectedEndpoint = selectedEndpoint.flatMap {
            CloudRoutePreferences.validLocalEndpoint($0) ? $0 : nil
        }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [path, action]
            process.standardOutput = pipe
            process.standardError = pipe
            if let validSelectedEndpoint {
                var environment = ProcessInfo.processInfo.environment
                environment["CLOUDROUTE_MIXED"] = validSelectedEndpoint
                process.environment = environment
            }

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // A process command line or third-party response can contain a stray
                // non-UTF-8 byte. Preserve the rest of the health report instead of
                // discarding the complete buffer when that happens.
                let output = String(decoding: data, as: UTF8.self)
                return (process.terminationStatus, output)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }
}

private enum CloudPalette {
    static let statusGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let statusGray = Color.secondary
    static let statusOrange = Color.orange
    static let statusRed = Color.red
    static let networkBlue = Color(red: 0.13, green: 0.55, blue: 1.00)
    static let googleViolet = Color(red: 0.61, green: 0.48, blue: 1.00)
    static let reviewCyan = Color(red: 0.20, green: 0.72, blue: 0.82)
    static let rulesViolet = Color(red: 0.54, green: 0.42, blue: 0.96)
}

private enum MainWindowLayout {
    // Keep the dashboard legible at its smallest size, but let macOS users
    // resize the window to match their workspace instead of enforcing a ratio.
    static let minimumWidth: CGFloat = 640
    static let minimumContentHeight: CGFloat = 448
    static let defaultWidth: CGFloat = 680
    static let defaultHeight: CGFloat = 500
}

private enum CloudTypography {
    static let headline = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let headerDetail = Font.system(size: 12)
    static let metricLabel = Font.system(size: 11, weight: .medium)
    static func metricValue(monospaced: Bool = false) -> Font {
        .system(size: 18, weight: .semibold, design: monospaced ? .monospaced : .rounded)
    }
    static let actionTitle = Font.system(size: 14, weight: .semibold)
    static let actionDetail = Font.system(size: 10.5)
}

struct MetricCard: View {
    let metric: MetricState

    private var iconColor: Color {
        metric.level.color
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                Image(systemName: metric.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 38, height: 38)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(iconColor.opacity(0.13), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(metric.title)
                    .font(CloudTypography.metricLabel)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(CloudTypography.metricValue(monospaced: metric.title == "本地端口"))
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Circle()
                .fill(metric.level.color)
                .frame(width: 7, height: 7)
                .shadow(color: metric.level.color.opacity(0.25), radius: 3)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

struct KillSwitchCard: View {
    let metric: MetricState
    let isBusy: Bool
    let setEnabled: (Bool) -> Void

    private var iconColor: Color {
        switch metric.level {
        case .error: return metric.level.color
        case .warning: return .orange
        case .ok, .idle: return CloudPalette.statusGreen
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 38, height: 38)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(iconColor.opacity(0.13), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Kill Switch")
                    .font(CloudTypography.metricLabel)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(CloudTypography.metricValue())
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { metric.level == .ok },
                set: setEnabled
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(CloudPalette.statusGreen)
            .controlSize(.small)
            .disabled(isBusy)
            .help(metric.level == .ok ? "关闭防泄漏保护" : "开启防泄漏保护")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

enum HealthItemKind {
    case passed
    case warning
    case failed
    case info

    var color: Color {
        switch self {
        case .passed: return Color(red: 0.17, green: 0.66, blue: 0.43)
        case .warning: return .orange
        case .failed: return Color(red: 0.91, green: 0.31, blue: 0.29)
        case .info: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark"
        case .warning: return "exclamationmark"
        case .failed: return "exclamationmark"
        case .info: return "info"
        }
    }
}

struct HealthCheckItem: Identifiable {
    let id = UUID()
    let kind: HealthItemKind
    let text: String
}

struct HealthCheckSection: Identifiable {
    let id = UUID()
    let number: String
    let title: String
    let items: [HealthCheckItem]

    var hasFailure: Bool {
        items.contains { $0.kind == .failed }
    }

    var hasWarning: Bool {
        items.contains { $0.kind == .warning }
    }
}

enum IsolatedBrowserRoute: String {
    case defaultExit = "default"
    case googleChain = "google"

    var label: String {
        switch self {
        case .defaultExit: return "默认出口"
        case .googleChain: return "Google 链路"
        }
    }
}

struct HealthReport {
    let checkedAt: String?
    let sections: [HealthCheckSection]
    let passCount: Int
    let warningCount: Int
    let failCount: Int

    private static let sectionWeights: [String: Double] = [
        "1": 15,
        "2": 15,
        "3": 15,
        "4": 20,
        "5": 10,
        "6": 10,
        "7": 5,
        "8": 10
    ]

    var score: Int {
        var earned = 0.0
        for section in sections {
            guard let weight = Self.sectionWeights[section.number] else { continue }
            if section.hasFailure {
                continue
            }
            earned += section.hasWarning ? weight * 0.5 : weight
        }

        var value = Int(earned.rounded())
        if sections.contains(where: { ["1", "2", "3", "4"].contains($0.number) && $0.hasFailure }) {
            value = min(value, 49)
        } else if failCount > 0 {
            value = min(value, 69)
        }
        return max(0, min(100, value))
    }

    var scoreLabel: String {
        if score >= 90 { return "良好" }
        if score >= 50 { return "需改进" }
        return "异常"
    }

    init(output: String) {
        var timestamp: String?
        var parsedSections: [HealthCheckSection] = []
        var currentNumber = ""
        var currentTitle: String?
        var currentItems: [HealthCheckItem] = []
        var passed = 0
        var warnings = 0
        var failed = 0

        func flushSection() {
            guard let title = currentTitle, !currentItems.isEmpty else {
                currentItems = []
                return
            }
            parsedSections.append(
                HealthCheckSection(number: currentNumber, title: title, items: currentItems)
            )
            currentItems = []
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("检查时间:") {
                timestamp = line.replacingOccurrences(of: "检查时间:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("=====") {
                let label = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                flushSection()

                if label.hasPrefix("结果:") {
                    currentTitle = nil
                    continue
                }

                if let separator = label.firstIndex(of: ".") {
                    currentNumber = String(label[..<separator])
                    currentTitle = String(label[label.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    currentNumber = String(parsedSections.count + 1)
                    currentTitle = label
                }
                continue
            }

            guard currentTitle != nil else { continue }

            if line.hasPrefix("✅") {
                passed += 1
                currentItems.append(
                    HealthCheckItem(
                        kind: .passed,
                        text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if line.hasPrefix("❌") {
                failed += 1
                currentItems.append(
                    HealthCheckItem(
                        kind: .failed,
                        text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if line.hasPrefix("⚠️") {
                warnings += 1
                currentItems.append(
                    HealthCheckItem(
                        kind: .warning,
                        text: line.replacingOccurrences(of: "⚠️", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if line.hasPrefix("ℹ️") {
                currentItems.append(
                    HealthCheckItem(
                        kind: .info,
                        text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                )
            } else if !line.hasPrefix("🎉") && !line.hasPrefix("⚠️") {
                currentItems.append(HealthCheckItem(kind: .info, text: line))
            }
        }

        flushSection()
        checkedAt = timestamp
        sections = parsedSections
        passCount = passed
        warningCount = warnings
        failCount = failed
    }

}

struct HealthItemRow: View {
    let item: HealthCheckItem

    private var linkedText: (label: String, url: URL)? {
        guard let range = item.text.range(of: "https://") else { return nil }
        let rawURL = String(item.text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else { return nil }
        let label = String(item.text[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ：:"))
        return (label.isEmpty ? url.host ?? "深度检测" : label, url)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(item.kind.color.opacity(item.kind == .info ? 0.10 : 0.15))
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(item.kind.color)
            }
            .frame(width: 20, height: 20)

            if let linkedText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(linkedText.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Link(destination: linkedText.url) {
                        Label("打开", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                }
                .font(.system(size: 13))
            } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(item.kind == .info ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HealthSectionCard: View {
    let section: HealthCheckSection

    private var accent: Color {
        if section.hasFailure { return Color(red: 0.91, green: 0.31, blue: 0.29) }
        if section.hasWarning { return .orange }
        return .blue
    }

    private var statusSymbol: String {
        if section.hasFailure { return "xmark.circle.fill" }
        if section.hasWarning { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(section.number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(section.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: statusSymbol)
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items) { item in
                        HealthItemRow(item: item)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(section.hasFailure || section.hasWarning ? accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct ResultView: View {
    let result: ResultSheet
    let close: () -> Void
    @State private var copied = false

    @ViewBuilder
    var body: some View {
        switch result.kind {
        case .health:
            healthResult
        case .standard:
            standardResult
        }
    }

    private var report: HealthReport {
        HealthReport(output: result.output)
    }

    private var healthColor: Color {
        if report.failCount > 0 || (!result.success && report.sections.isEmpty) {
            return Color(red: 0.91, green: 0.31, blue: 0.29)
        }
        if report.warningCount > 0 { return .orange }
        return Color(red: 0.17, green: 0.66, blue: 0.43)
    }

    private var healthTitle: String {
        if report.sections.isEmpty { return "未收到检查详情" }
        if report.failCount > 0 { return "发现 \(report.failCount) 项问题" }
        if report.warningCount > 0 { return "网络可用，仍有 \(report.warningCount) 项提示" }
        return "网络检查通过"
    }

    private var scoreColor: Color {
        if report.score >= 90 { return Color(red: 0.17, green: 0.66, blue: 0.43) }
        if report.score >= 50 { return .orange }
        return Color(red: 0.91, green: 0.31, blue: 0.29)
    }

    @ViewBuilder
    private var healthResult: some View {
        if report.sections.isEmpty {
            emptyHealthResult
        } else {
            detailedHealthResult
        }
    }

    private var detailedHealthResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(healthColor.opacity(0.13))
                    Image(systemName: report.failCount == 0 && report.warningCount == 0 && result.success ? "checkmark" : "exclamationmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(healthColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(healthTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let checkedAt = report.checkedAt {
                        Text(checkedAt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(scoreColor.opacity(0.14), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: Double(report.score) / 100)
                            .stroke(scoreColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(report.score)")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreColor)
                    }
                    .frame(width: 50, height: 50)
                    Text("健康分 · \(report.scoreLabel)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(scoreColor)
                }
            }

            HStack(spacing: 8) {
                Label("关键链路加权；高级检测不计分", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                summaryBadge("\(report.passCount) 通过", color: Color(red: 0.17, green: 0.66, blue: 0.43))
                if report.warningCount > 0 {
                    summaryBadge("\(report.warningCount) 提示", color: .orange)
                }
                summaryBadge("\(report.failCount) 失败", color: report.failCount == 0 ? .secondary : healthColor)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(report.sections) { section in
                        HealthSectionCard(section: section)
                    }
                }
                .padding(.vertical, 1)
            }

            HStack {
                Button(copied ? "已复制" : "复制报告", action: copyResult)
                    .controlSize(.small)
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 520)
    }

    private var emptyHealthResult: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.orange.opacity(0.13))
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text("未收到检查详情")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("健康检查没有返回可解析的项目。请关闭弹窗后重新运行；如果反复出现，请检查本地脚本。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if shouldOfferHealthCopy {
                    Button(copied ? "已复制" : "复制详情", action: copyResult)
                        .controlSize(.small)
                }
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480, height: 210)
    }

    private var shouldOfferHealthCopy: Bool {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !output.isEmpty && output != "操作已完成。" && !output.hasPrefix("健康检查没有返回详情")
    }

    private func summaryBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var standardAccent: Color {
        if !result.success { return Color(red: 0.91, green: 0.31, blue: 0.29) }
        if result.title.contains("关闭") { return .orange }
        return Color(red: 0.17, green: 0.66, blue: 0.43)
    }

    private var standardSymbol: String {
        if !result.success { return "xmark" }
        if result.title.contains("关闭") { return "shield.slash.fill" }
        if result.title.contains("Kill Switch") { return "shield.checkered" }
        return "checkmark"
    }

    private var standardSubtitle: String {
        if !result.success { return "操作没有完成，请查看下面的具体原因。" }
        if result.title.contains("关闭") { return "保护已关闭，应用可能通过真实 IP 直接连接网络。" }
        if result.title.contains("Kill Switch") { return "防泄漏保护正在工作，代理中断时会阻止真实 IP 直连。" }
        return "操作已经完成。"
    }

    private var standardResult: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(standardAccent.opacity(0.13))
                    Image(systemName: standardSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(standardAccent)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(result.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(standardSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !result.success {
                ScrollView {
                    Text(result.output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 104)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            HStack {
                if !result.success {
                    Button(copied ? "已复制" : "复制错误", action: copyResult)
                        .controlSize(.small)
                }
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470, height: result.success ? 210 : 330)
    }

    private func copyResult() {
        var copiedOutput = result.output
        if case .health = result.kind, !report.sections.isEmpty {
            copiedOutput = "健康分：\(report.score)/100 · \(report.scoreLabel)\n\(copiedOutput)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedOutput, forType: .string)
        copied = true
    }

}

private struct DiagnosticActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct DashboardActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let actionLabel: String
    let actionSymbol: String
    let tint: Color
    var scopeLabels: [String] = []
    var isRunning = false
    var isDisabled = false
    var showsProgress = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.14))
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(CloudTypography.actionTitle)
                        Text(detail)
                            .font(CloudTypography.actionDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !scopeLabels.isEmpty {
                        Text(scopeLabels.joined(separator: "  ·  "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .layoutPriority(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(tint)
                        } else {
                            Image(systemName: actionSymbol)
                                .font(.system(size: 10, weight: .bold))
                        }

                        Text(isRunning ? "检查中" : actionLabel)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .frame(minWidth: 58)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(isHovering ? 0.24 : 0.14))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(tint.opacity(isHovering ? 0.58 : 0.30), lineWidth: 1)
                    }
                }

                if showsProgress && isRunning {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .controlSize(.small)
                        .accessibilityLabel("\(title)正在运行")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(DiagnosticActionButtonStyle())
        .background(
            isHovering && !isDisabled
                ? tint.opacity(0.055)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isHovering && !isDisabled ? tint.opacity(0.32) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        }
        .opacity(isDisabled && !isRunning ? 0.58 : 1)
        .allowsHitTesting(!isDisabled)
        .accessibilityValue(isRunning ? "正在运行" : "")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct AdvancedCheckCard: View {
    let action: () -> Void

    var body: some View {
        DashboardActionCard(
            title: "高级检测",
            detail: "浏览器泄漏与 IP 风险",
            symbol: "scope",
            actionLabel: "打开",
            actionSymbol: "arrow.up.right",
            tint: CloudPalette.reviewCyan,
            action: action
        )
        .accessibilityLabel("打开高级检测")
        .help("按需打开隔离浏览器检测；结果不计入健康检查")
    }
}

struct AdvancedCheckView: View {
    let close: () -> Void
    @State private var message = ""
    @State private var browserProcesses: [Process] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CloudPalette.reviewCyan.opacity(0.14))
                    Image(systemName: "scope")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CloudPalette.reviewCyan)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("高级检测")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("按需复核浏览器泄漏与 IP 风险")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("不计入健康结果")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CloudPalette.reviewCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CloudPalette.reviewCyan.opacity(0.11), in: Capsule())
            }

            HStack(spacing: 12) {
                routeButton(
                    title: "默认出口",
                    detail: "BrowserLeaks · IPhey · IPQS",
                    note: "使用本地 mixed 入口",
                    symbol: "network",
                    tint: CloudPalette.networkBlue,
                    route: .defaultExit
                )
                routeButton(
                    title: "Google 链路",
                    detail: "复核专用链式出口",
                    note: "需已配置专用入口",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: CloudPalette.googleViolet,
                    route: .googleChain
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("使用临时 Chrome 资料，不加载现有登录、扩展或同步数据。", systemImage: "person.crop.circle.badge.minus")
                Label("不会改变系统代理；检测网站仍会看到所选出口 IP。", systemImage: "lock.shield")
                Label("关闭临时窗口后，浏览器资料会自动清理。", systemImage: "trash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                if !message.isEmpty {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 540, height: 330)
    }

    private func routeButton(
        title: String,
        detail: String,
        note: String,
        symbol: String,
        tint: Color,
        route: IsolatedBrowserRoute
    ) -> some View {
        Button {
            launchIsolatedBrowser(route)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint.opacity(0.75))
                }
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(note)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("用\(title)打开独立的临时 Chrome 检测窗口")
    }

    private func launchIsolatedBrowser(_ route: IsolatedBrowserRoute) {
        let bundledPath = Bundle.main.path(forResource: "cloudroute-private-browser", ofType: "sh")
        let fallbackPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/cloudroute-private-browser").path
        let scriptPath = bundledPath ?? fallbackPath

        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            message = "高级检测组件不可用，请重新安装 CloudRoute。"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, route.rawValue, ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let endpoint = UserDefaults.standard.string(forKey: CloudRoutePreferences.selectedEndpointKey),
           CloudRoutePreferences.validLocalEndpoint(endpoint) {
            var environment = ProcessInfo.processInfo.environment
            environment["CLOUDROUTE_MIXED"] = endpoint
            process.environment = environment
        }

        do {
            try process.run()
            browserProcesses.append(process)
            message = "已用\(route.label)打开临时窗口；关闭窗口后会自动清理资料。"
        } catch {
            message = "无法打开临时窗口：\(error.localizedDescription)"
        }
    }
}

struct RulePackCard: View {
    let action: () -> Void

    var body: some View {
        DashboardActionCard(
            title: "规则管理",
            detail: "12 条 · 2026.08",
            symbol: "list.bullet.rectangle",
            actionLabel: "管理",
            actionSymbol: "chevron.right",
            tint: CloudPalette.rulesViolet,
            action: action
        )
        .accessibilityLabel("打开规则管理")
        .help("管理可分享的 Mihomo / Clash Verge 规则包")
    }
}

struct RulePackView: View {
    let close: () -> Void
    @State private var preview = ""
    @State private var copied = false
    @State private var message = ""

    private let version = "2026.08"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CloudPalette.rulesViolet.opacity(0.15))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CloudPalette.rulesViolet)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text("CloudRoute 规则包")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("分流规则与 TUN DNS · 版本 \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("不含订阅")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CloudPalette.rulesViolet)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CloudPalette.rulesViolet.opacity(0.11), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("适用于 Clash Verge Rev 的 Merge 配置；不会读取或保存节点、订阅地址与凭据。", systemImage: "lock.shield")
                Label("默认策略组名为 PROXY；朋友的订阅若使用其他名称，导入前替换规则最后一列。", systemImage: "arrow.triangle.branch")
                Label("导入后在 Clash Verge Rev 中启用该 Merge 配置并刷新当前订阅。", systemImage: "arrow.clockwise")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("规则预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("12 条域名规则")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ScrollView([.vertical, .horizontal]) {
                    Text(preview.isEmpty ? "规则资源不可用" : preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .frame(maxHeight: 225)

            HStack(spacing: 9) {
                Button(copied ? "已复制" : "复制 YAML", action: copyRules)
                Button("导出…", action: exportRules)
                    .buttonStyle(.borderedProminent)

                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                Button("完成", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
        .onAppear(perform: loadPreview)
    }

    private var bundledRuleURL: URL? {
        Bundle.main.url(forResource: "CloudRoute-Merge", withExtension: "yaml", subdirectory: "Rules")
    }

    private func loadPreview() {
        guard let url = bundledRuleURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            preview = ""
            return
        }
        preview = content
    }

    private func copyRules() {
        guard !preview.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview, forType: .string)
        copied = true
        message = "可以粘贴到新的 Merge 配置"
    }

    private func exportRules() {
        guard let source = bundledRuleURL else {
            message = "找不到内置规则资源"
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出 CloudRoute 规则包"
        panel.nameFieldStringValue = "CloudRoute-Merge.yaml"
        panel.canCreateDirectories = true
        if let yamlType = UTType(filenameExtension: "yaml") {
            panel.allowedContentTypes = [yamlType]
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            message = "已导出 \(destination.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct ConnectionSetupView: View {
    let discovery: ProxyDiscovery
    let isDiscovering: Bool
    let confirm: (String) -> Void
    let redetect: () -> Void
    let deferSetup: () -> Void

    @State private var manualMode = false
    @State private var manualPort = "7890"

    private var parsedPort: Int? {
        guard let port = Int(manualPort), (1...65535).contains(port) else { return nil }
        return port
    }

    private var modeColor: Color {
        switch discovery.mode {
        case "TUN", "系统代理": return CloudPalette.statusGreen
        case "双重入口": return CloudPalette.statusOrange
        default: return CloudPalette.statusGray
        }
    }

    private var modeSymbol: String {
        switch discovery.mode {
        case "TUN": return "arrow.triangle.2.circlepath"
        case "系统代理": return "network"
        case "双重入口": return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.branch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CloudPalette.networkBlue.opacity(0.14))
                    Image(systemName: discovery.found ? "point.3.connected.trianglepath.dotted" : "network.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CloudPalette.networkBlue)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 5) {
                    Text(discovery.found ? "已找到本地代理" : "连接本地代理")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(discovery.found
                         ? "确认一次即可开始使用 CloudRoute。"
                         : "启动 Clash Verge 或 Mihomo，CloudRoute 会自动识别。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: redetect) {
                    if isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.borderless)
                .padding(7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(isDiscovering)
                .help("重新检测本地代理")
            }

            if manualMode {
                manualSetup
            } else {
                detectedRoute
            }

            Label(discovery.privacy, systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("稍后", action: deferSetup)
                    .controlSize(.small)

                Spacer()

                if discovery.found {
                    Button(manualMode ? "使用检测结果" : "手动设置") {
                        manualMode.toggle()
                    }
                    .controlSize(.small)
                }

                Button(manualMode ? "保存并继续" : "使用检测结果") {
                    if manualMode, let port = parsedPort {
                        confirm("127.0.0.1:\(port)")
                    } else {
                        confirm(discovery.endpoint)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isDiscovering || (manualMode && parsedPort == nil) || (!manualMode && !discovery.found))
            }
        }
        .padding(22)
        .frame(width: 540, height: manualMode ? 350 : 330)
        .interactiveDismissDisabled()
        .onAppear(perform: syncFromDiscovery)
        .onChange(of: discovery) { _, _ in
            syncFromDiscovery()
        }
    }

    private var detectedRoute: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 0) {
                routeNode(
                    symbol: "app.connected.to.app.below.fill",
                    title: "代理客户端",
                    value: discovery.client,
                    color: CloudPalette.networkBlue
                )
                routeConnector(color: discovery.found ? CloudPalette.networkBlue : CloudPalette.statusGray)
                routeNode(
                    symbol: discovery.active ? "checkmark.circle.fill" : "pause.circle.fill",
                    title: "本地入口",
                    value: discovery.endpoint,
                    color: discovery.active ? CloudPalette.statusGreen : CloudPalette.statusOrange
                )
                routeConnector(color: modeColor)
                routeNode(
                    symbol: modeSymbol,
                    title: "流量模式",
                    value: discovery.mode,
                    color: modeColor
                )
            }

            HStack {
                Text(discovery.active ? "入口正在监听" : "已找到设置，端口当前未监听")
                    .foregroundStyle(discovery.active ? CloudPalette.statusGreen : CloudPalette.statusOrange)
                Spacer()
                Text("来源：\(discovery.source)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var manualSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地代理端口")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Text("127.0.0.1 :")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("7890", text: $manualPort)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(width: 94)
                Spacer()
            }

            Text(parsedPort == nil
                 ? "请输入 1–65535 之间的端口。"
                 : "只连接本机回环地址，不会访问局域网或远程代理。")
                .font(.caption)
                .foregroundStyle(parsedPort == nil ? CloudPalette.statusRed : .secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func routeNode(symbol: String, title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 30, height: 30)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 132)
    }

    private func routeConnector(color: Color) -> some View {
        Rectangle()
            .fill(color.opacity(0.42))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .offset(y: -18)
    }

    private func syncFromDiscovery() {
        if let port = discovery.endpoint.split(separator: ":").last,
           Int(port) != nil {
            manualPort = String(port)
        }
        manualMode = !discovery.found
    }
}

struct ContentView: View {
    @StateObject private var model = ProxyModel()
    @State private var showingAdvanced = false
    @State private var showingRules = false

    var body: some View {
        VStack(spacing: 14) {
            header

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                spacing: 12
            ) {
                MetricCard(metric: model.core)
                MetricCard(metric: model.port)
                MetricCard(metric: model.entry)
                KillSwitchCard(metric: model.killSwitch, isBusy: model.isBusy) { enabled in
                    if enabled {
                        model.enableKillSwitch()
                    } else {
                        model.showDisableConfirmation = true
                    }
                }
            }

            actionArea
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(
            minWidth: MainWindowLayout.minimumWidth,
            maxWidth: .infinity,
            minHeight: MainWindowLayout.minimumContentHeight,
            maxHeight: .infinity,
            alignment: .top
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.resultSheet) { result in
            ResultView(result: result) {
                model.resultSheet = nil
            }
        }
        .sheet(isPresented: $showingRules) {
            RulePackView {
                showingRules = false
            }
        }
        .sheet(isPresented: $showingAdvanced) {
            AdvancedCheckView {
                showingAdvanced = false
            }
        }
        .sheet(isPresented: $model.showConnectionSetup) {
            ConnectionSetupView(
                discovery: model.discovery,
                isDiscovering: model.isDiscoveringConnection,
                confirm: model.confirmConnection,
                redetect: {
                    Task { await model.discoverConnection() }
                },
                deferSetup: model.deferConnectionSetup
            )
        }
        .alert("关闭 Kill Switch？", isPresented: $model.showDisableConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认关闭", role: .destructive) {
                model.disableKillSwitch()
            }
        } message: {
            Text("关闭后，代理意外中断时，应用可能使用真实 IP 直连外网。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(model.overallLevel.color)
                        .frame(width: 8, height: 8)
                    Text(model.headline)
                        .font(CloudTypography.headline)
                }
                Text(model.detail)
                    .font(CloudTypography.headerDetail)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Button(action: model.openConnectionSetup) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(model.isBusy || model.isRefreshing)
                .help("连接设置")

                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(CloudPalette.networkBlue)
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(CloudPalette.networkBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(model.isBusy || model.isRefreshing)
                .help("刷新状态")
            }
        }
    }

    private var actionArea: some View {
        VStack(spacing: 10) {
            DashboardActionCard(
                title: "健康检查",
                detail: isHealthCheckRunning ? "正在检查代理链路…" : "自动检查代理链路",
                symbol: "stethoscope",
                actionLabel: "检查",
                actionSymbol: "play.fill",
                tint: CloudPalette.networkBlue,
                scopeLabels: ["双出口", "IP 风险", "域名分流"],
                isRunning: isHealthCheckRunning,
                isDisabled: model.isBusy,
                showsProgress: true,
                action: model.runHealthCheck
            )
            .accessibilityLabel(isHealthCheckRunning ? "健康检查正在运行" : "开始健康检查")
            .help(isHealthCheckRunning ? "正在检查代理链路" : "开始健康检查")

            HStack(spacing: 10) {
                AdvancedCheckCard { showingAdvanced = true }
                RulePackCard { showingRules = true }
            }
        }
    }

    private var isHealthCheckRunning: Bool {
        model.isBusy && model.busyLabel.contains("全面检查")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var singletonLockFD: Int32 = -1
    private var ownsSingletonLock = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("com.valenlan.cloudroute.lock")
        singletonLockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard singletonLockFD >= 0,
              flock(singletonLockFD, LOCK_EX | LOCK_NB) == 0 else {
            if singletonLockFD >= 0 {
                Darwin.close(singletonLockFD)
                singletonLockFD = -1
            }

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.valenlan.cloudroute")
                .first { $0.processIdentifier != currentPID && !$0.isTerminated }
            existing?.activate(options: [.activateAllWindows])

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        ownsSingletonLock = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ownsSingletonLock else { return }
        NSApp.setActivationPolicy(.regular)
        applyApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.applyApplicationIcon()
        }
    }

    private func applyApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "CloudRoute", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard singletonLockFD >= 0 else { return }
        flock(singletonLockFD, LOCK_UN)
        Darwin.close(singletonLockFD)
        singletonLockFD = -1
    }
}

@main
struct CloudRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CloudRoute", id: "main") {
            ContentView()
        }
        .defaultSize(
            width: MainWindowLayout.defaultWidth,
            height: MainWindowLayout.defaultHeight
        )
        .windowResizability(.contentMinSize)
    }
}
