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
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .idle: return .secondary
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
    let title: String
    let symbol: String
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

    @Published var core = MetricState(title: "代理核心", symbol: "cpu", value: "检查中", level: .idle)
    @Published var port = MetricState(title: "本地端口", symbol: "network", value: "检查中", level: .idle)
    @Published var tun = MetricState(title: "TUN 路由", symbol: "arrow.triangle.2.circlepath", value: "检查中", level: .idle)
    @Published var killSwitch = MetricState(title: "Kill Switch", symbol: "shield.fill", value: "未确认", level: .idle)

    private let backendPath = Bundle.main.path(forResource: "cloudroute-backend", ofType: "sh")
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/cloudroute/cloudroute-backend.sh").path

    init() {
        Task { [weak self] in
            await self?.refresh()
        }
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
        updateMetric(&tun, from: parsed["tun"])
        updateMetric(&killSwitch, from: parsed["kill"])
    }

    private func updateMetric(_ metric: inout MetricState, from fields: [String]?) {
        guard let fields, fields.count >= 2 else { return }
        metric.value = fields[0]
        metric.level = HealthLevel(rawValue: fields[1]) ?? .idle
    }

    private func execute(_ action: String) async -> (status: Int32, output: String) {
        let path = backendPath
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [path, action]
            process.standardOutput = pipe
            process.standardError = pipe

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
    static let coreMint = Color(red: 0.22, green: 0.82, blue: 0.48)
    static let portSky = Color(red: 0.29, green: 0.66, blue: 1.00)
    static let tunnelLilac = Color(red: 0.61, green: 0.48, blue: 1.00)
    static let guardTeal = Color(red: 0.20, green: 0.78, blue: 0.69)
    static let healthAzure = Color(red: 0.13, green: 0.55, blue: 1.00)
    static let rulesViolet = Color(red: 0.54, green: 0.42, blue: 0.96)
}

struct MetricCard: View {
    let metric: MetricState
    let accent: Color

    private var iconColor: Color {
        switch metric.level {
        case .error: return metric.level.color
        case .warning: return .orange
        case .ok, .idle: return accent
        }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.system(
                        size: 17,
                        weight: .semibold,
                        design: metric.title == "本地端口" ? .monospaced : .rounded
                    ))
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
        .frame(maxWidth: .infinity, minHeight: 70)
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
        case .ok, .idle: return CloudPalette.guardTeal
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { metric.level == .ok },
                set: setEnabled
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isBusy)
            .help(metric.level == .ok ? "关闭防泄漏保护" : "开启防泄漏保护")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 70)
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

    var defaultExitIP: String? {
        firstIPv4(in: sections.first { $0.number == "4" })
    }

    var googleExitIP: String? {
        guard let chainSection = sections.first(where: { $0.number == "6" }) else { return nil }
        for item in chainSection.items where item.text.contains("确认 Google / Gemini 出口一致") {
            if let address = Self.ipv4(in: item.text) { return address }
        }
        return nil
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

    private func firstIPv4(in section: HealthCheckSection?) -> String? {
        guard let section else { return nil }
        for item in section.items {
            if let address = Self.ipv4(in: item.text) { return address }
        }
        return nil
    }

    private static func ipv4(in text: String) -> String? {
        let pattern = #"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
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
    let isolationMessage: String?
    let launchIsolatedBrowser: ((IsolatedBrowserRoute) -> Void)?

    init(
        section: HealthCheckSection,
        isolationMessage: String? = nil,
        launchIsolatedBrowser: ((IsolatedBrowserRoute) -> Void)? = nil
    ) {
        self.section = section
        self.isolationMessage = isolationMessage
        self.launchIsolatedBrowser = launchIsolatedBrowser
    }

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

    private var offersIsolation: Bool {
        section.title.contains("社区深度复核") && launchIsolatedBrowser != nil
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

                if offersIsolation {
                    isolatedBrowserPanel
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


    private var isolatedBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(CloudPalette.portSky.opacity(0.14))
                    Image(systemName: "safari.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CloudPalette.portSky)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text("隔离浏览器检测")
                        .font(.system(size: 13, weight: .semibold))
                    Text("临时 Chrome 资料 · 无现有登录和扩展 · 不改变系统代理")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                isolationButton(
                    "默认出口",
                    symbol: "network",
                    tint: CloudPalette.portSky,
                    route: .defaultExit
                )
                isolationButton(
                    "Google 链路",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: CloudPalette.tunnelLilac,
                    route: .googleChain
                )
                Spacer(minLength: 0)
            }

            if let isolationMessage, !isolationMessage.isEmpty {
                Label(isolationMessage, systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("检测网站仍会看到所选出口 IP；账号状态必须在你的已登录会话中确认。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(CloudPalette.portSky.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(CloudPalette.portSky.opacity(0.13), lineWidth: 1)
        }
    }

    private func isolationButton(
        _ title: String,
        symbol: String,
        tint: Color,
        route: IsolatedBrowserRoute
    ) -> some View {
        Button {
            launchIsolatedBrowser?(route)
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.11), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("用\(title)打开独立的临时 Chrome 检测窗口")
    }
}

struct ResultView: View {
    let result: ResultSheet
    let close: () -> Void
    @State private var copied = false
    @State private var isolationMessage = ""
    @State private var isolatedBrowserProcesses: [Process] = []

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

                HStack(spacing: 7) {
                    summaryBadge("\(report.passCount) 通过", color: Color(red: 0.17, green: 0.66, blue: 0.43))
                    if report.warningCount > 0 {
                        summaryBadge("\(report.warningCount) 提示", color: .orange)
                    }
                    summaryBadge("\(report.failCount) 失败", color: report.failCount == 0 ? .secondary : healthColor)
                }
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(report.sections) { section in
                        HealthSectionCard(
                            section: section,
                            isolationMessage: isolationMessage.isEmpty ? nil : isolationMessage,
                            launchIsolatedBrowser: section.title.contains("社区深度复核")
                                ? launchIsolatedBrowser
                                : nil
                        )
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
        .frame(width: 610, height: 490)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.output, forType: .string)
        copied = true
    }

    private func launchIsolatedBrowser(_ route: IsolatedBrowserRoute) {
        let bundledPath = Bundle.main.path(forResource: "cloudroute-private-browser", ofType: "sh")
        let fallbackPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/cloudroute-private-browser").path
        let scriptPath = bundledPath ?? fallbackPath

        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            isolationMessage = "隔离浏览器组件不可用，请重新安装 CloudRoute。"
            return
        }

        let exitIP: String?
        switch route {
        case .defaultExit:
            exitIP = report.defaultExitIP
        case .googleChain:
            exitIP = report.googleExitIP
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, route.rawValue, exitIP ?? ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            isolatedBrowserProcesses.append(process)
            isolationMessage = "已用\(route.label)打开隔离窗口；关闭窗口后会自动清理临时资料。"
        } catch {
            isolationMessage = "无法打开隔离窗口：\(error.localizedDescription)"
        }
    }
}

struct RulePackCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(CloudPalette.rulesViolet.opacity(0.15))
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CloudPalette.rulesViolet)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("规则管理")
                        .font(.callout.weight(.semibold))
                    Text("12 条规则 · 版本 2026.08")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text("管理")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CloudPalette.rulesViolet)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(CloudPalette.rulesViolet.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
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

struct ContentView: View {
    @StateObject private var model = ProxyModel()
    @State private var showingRules = false

    var body: some View {
        VStack(spacing: 14) {
            header

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                spacing: 12
            ) {
                MetricCard(metric: model.core, accent: CloudPalette.coreMint)
                MetricCard(metric: model.port, accent: CloudPalette.portSky)
                MetricCard(metric: model.tun, accent: CloudPalette.tunnelLilac)
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
        .padding(20)
        .frame(width: 720, height: 348)
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
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                }
                Text(model.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(CloudPalette.portSky)
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
            .background(CloudPalette.portSky.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .disabled(model.isBusy || model.isRefreshing)
            .help("刷新状态")
        }
    }

    private var actionArea: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(CloudPalette.healthAzure.opacity(0.15))
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CloudPalette.healthAzure)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("健康检查")
                        .font(.callout.weight(.semibold))
                    Text(model.isBusy && model.busyLabel.contains("全面检查") ? "正在检查代理链路…" : "检查双出口、IP 风险与域名分流")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    model.runHealthCheck()
                } label: {
                    if model.isBusy && model.busyLabel.contains("全面检查") {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("开始")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }

            RulePackCard {
                showingRules = true
            }
        }
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
        WindowGroup("CloudRoute") {
            ContentView()
        }
        .defaultSize(width: 720, height: 348)
        .windowResizability(.contentSize)
    }
}
