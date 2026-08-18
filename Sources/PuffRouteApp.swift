import AppKit
import Darwin
import SwiftUI

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

    private let backendPath = Bundle.main.path(forResource: "puffroute-backend", ofType: "sh")
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/puffroute/puffroute-backend.sh").path

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
            self.isBusy = false
            self.busyLabel = ""
            self.resultSheet = ResultSheet(
                kind: action == "health" ? .health : .standard,
                title: action == "health" ? title : (result.status == 0 ? title : "操作失败"),
                output: cleanOutput.isEmpty
                    ? (result.status == 0 ? "操作已完成。" : "没有收到操作结果。")
                    : cleanOutput,
                success: result.status == 0
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
                let output = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, output)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }
}

struct MetricCard: View {
    let metric: MetricState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(metric.level.color.opacity(0.14))
                Image(systemName: metric.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(metric.level.color)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

enum HealthItemKind {
    case passed
    case failed
    case info

    var color: Color {
        switch self {
        case .passed: return Color(red: 0.17, green: 0.66, blue: 0.43)
        case .failed: return Color(red: 0.91, green: 0.31, blue: 0.29)
        case .info: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark"
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
}

struct HealthReport {
    let checkedAt: String?
    let sections: [HealthCheckSection]
    let passCount: Int
    let failCount: Int

    init(output: String) {
        var timestamp: String?
        var parsedSections: [HealthCheckSection] = []
        var currentNumber = ""
        var currentTitle: String?
        var currentItems: [HealthCheckItem] = []
        var passed = 0
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
        failCount = failed
    }
}

struct HealthItemRow: View {
    let item: HealthCheckItem

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

            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(item.kind == .info ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HealthSectionCard: View {
    let section: HealthCheckSection

    private var accent: Color {
        section.hasFailure ? Color(red: 0.91, green: 0.31, blue: 0.29) : .blue
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
                    Image(systemName: section.hasFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
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
                .stroke(section.hasFailure ? accent.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
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
        return Color(red: 0.17, green: 0.66, blue: 0.43)
    }

    private var healthTitle: String {
        if report.failCount > 0 { return "发现 \(report.failCount) 项问题" }
        if !result.success && report.sections.isEmpty { return "检查未完成" }
        return "代理链路正常"
    }

    private var healthSubtitle: String {
        guard !report.sections.isEmpty else { return result.output }
        return "\(report.passCount) 项通过 · \(report.failCount) 项未通过"
    }

    private var healthResult: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(healthColor.opacity(0.13))
                    Image(systemName: report.failCount == 0 && result.success ? "checkmark" : "exclamationmark")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(healthColor)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(healthTitle)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(healthSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if let checkedAt = report.checkedAt {
                    Text(checkedAt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .padding(16)
            .background(healthColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(healthColor.opacity(0.16), lineWidth: 1)
            }

            ScrollView {
                if report.sections.isEmpty {
                    Text(result.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(report.sections) { section in
                            HealthSectionCard(section: section)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            HStack {
                Button(copied ? "已复制" : "复制完整报告", action: copyResult)
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 540)
    }

    private var standardResult: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(result.success ? Color.green : Color.red)
                Text(result.title)
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            ScrollView {
                Text(result.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Button(copied ? "已复制" : "复制结果", action: copyResult)
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 420)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.output, forType: .string)
        copied = true
    }
}

struct ContentView: View {
    @StateObject private var model = ProxyModel()

    var body: some View {
        VStack(spacing: 18) {
            header

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                MetricCard(metric: model.core)
                MetricCard(metric: model.port)
                MetricCard(metric: model.tun)
            }

            actionArea
        }
        .padding(22)
        .frame(width: 620, height: 290)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.resultSheet) { result in
            ResultView(result: result) {
                model.resultSheet = nil
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
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: model.overallLevel.systemImage)
                        .foregroundStyle(model.overallLevel.color)
                    Text(model.headline)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                }
                Text(model.detail)
                    .font(.callout)
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
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy || model.isRefreshing)
            .help("刷新状态")
        }
    }

    private var killSwitchDescription: String {
        if model.isBusy && !model.busyLabel.contains("全面检查") {
            return model.busyLabel
        }
        switch model.killSwitch.level {
        case .ok:
            return "代理中断时阻止真实 IP 直连"
        case .warning:
            return "保护未开启，流量可能直接连接"
        case .error:
            return "状态读取失败，请重新开启保护"
        case .idle:
            return "尚未取得管理员验证状态"
        }
    }

    private var actionArea: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.13))
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("健康检查")
                        .font(.callout.weight(.semibold))
                    Text(model.isBusy && model.busyLabel.contains("全面检查") ? "正在检查代理链路…" : "检查出口与站点可达性")
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
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }

            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(model.killSwitch.level.color.opacity(0.13))
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.killSwitch.level.color)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Kill Switch")
                            .font(.callout.weight(.semibold))

                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.killSwitch.level.color)
                                .frame(width: 6, height: 6)
                            Text(model.killSwitch.value)
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(model.killSwitch.level.color.opacity(0.12), in: Capsule())
                    }

                    Text(killSwitchDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if model.killSwitch.level == .ok {
                    Button("关闭") {
                        model.showDisableConfirmation = true
                    }
                    .tint(.red)
                } else {
                    Button("开启", action: model.enableKillSwitch)
                        .tint(.blue)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .disabled(model.isBusy)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var singletonLockFD: Int32 = -1
    private var ownsSingletonLock = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("com.valenlan.puffroute.lock")
        singletonLockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard singletonLockFD >= 0,
              flock(singletonLockFD, LOCK_EX | LOCK_NB) == 0 else {
            if singletonLockFD >= 0 {
                Darwin.close(singletonLockFD)
                singletonLockFD = -1
            }

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.valenlan.puffroute")
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
        guard let iconURL = Bundle.main.url(forResource: "PuffRoute", withExtension: "icns"),
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
struct PuffRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PuffRoute") {
            ContentView()
        }
        .defaultSize(width: 620, height: 290)
        .windowResizability(.contentSize)
    }
}
