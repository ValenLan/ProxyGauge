import AppKit
import CFNetwork
import CryptoKit
import Darwin
import Network
import SystemConfiguration
import SwiftUI
import UniformTypeIdentifiers

private final class SystemNetworkChangeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.valenlan.proxygauge.system-network-change")
    private let onChange: @Sendable () -> Void
    private var store: SCDynamicStore?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "ProxyGauge.NetworkChange" as CFString,
            { _, _, info in
                guard let info else { return }
                let monitor = Unmanaged<SystemNetworkChangeMonitor>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                monitor.onChange()
            },
            &context
        ) else { return }

        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/Proxies",
            "Setup:/Network/Global/Proxies"
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Service/.*/IPv6",
            "State:/Network/Service/.*/Proxies"
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
              SCDynamicStoreSetDispatchQueue(store, queue) else { return }
        self.store = store
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    deinit {
        stop()
    }
}

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
    let status: Int32
}

struct ProxyDiscovery: Sendable, Equatable {
    var found = false
    var client = "正在检测"
    var core = ""
    var endpoint = "127.0.0.1:7890"
    var mode = "正在读取"
    var source = "本地运行状态"
    var active = false
    var privacy = "仅读取本地端口与运行模式，不读取订阅和节点"
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
    @Published var showHealthPlanSetup = false
    @Published var showGuardApplicationSelection = false
    @Published var guardApplications: [GuardApplicationChoice] = []
    @Published var guardSelection = GuardSelectionSnapshot.read()
    @Published var guardSelectionError = ""
    private var enableAfterSelection = false
    private var exitLoadingGate = ExitLoadingGate()
    private var exitDeadlineTask: Task<Void, Never>?
    private static let guardPreferenceKey = "proxygauge.guard.selectedCore.v1"
    var guardApplicationLabel: String {
        guardSelection?.ambiguous == true ? "选择当前代理" : ""
    }
    private var disconnectedByGuard: Bool {
        guard killSwitch.level == .ok, let guardSelection,
              guardSelection.tunnels == ["lo0"] else { return false }
        let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return (proxy[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue != true
            && (proxy[kCFNetworkProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue != true
            && (proxy[kCFNetworkProxiesSOCKSEnable as String] as? NSNumber)?.boolValue != true
    }
    private var unavailableExit: ExitSummarySnapshot {
        networkPathSatisfied == false || disconnectedByGuard ? .disconnected : .unavailable
    }
    private func beginExitLoading() {
        guard networkPathSatisfied != false else { exitSummary = .disconnected; return }
        guard exitLoadingGate.begin(at: Date()) else { exitSummary = unavailableExit; return }
        exitSummary = .checking
        guard exitDeadlineTask == nil else { return }
        exitDeadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self else { return }
            if self.exitSummary == .checking { self.exitSummary = self.unavailableExit }
        }
    }
    private func finishExitLoading(_ value: ExitSummarySnapshot) {
        exitDeadlineTask?.cancel(); exitDeadlineTask = nil; exitLoadingGate.finish()
        exitSummary = value == .unavailable ? unavailableExit : value
    }
    @Published var isDiscoveringConnection = false
    @Published var discovery = ProxyDiscovery()
    @Published var healthPlan = ProxyGaugePreferences.loadHealthPlan()
    @Published private var exitSummary =
        ExitSummaryPersistence.loadSummary() ?? .waitingForPathChange
    var exitAddress: String {
        get { exitSummary.address }
        set { exitSummary = ExitSummarySnapshot(address: newValue, location: exitSummary.location) }
    }
    var exitLocation: String {
        get { exitSummary.location }
        set { exitSummary = ExitSummarySnapshot(address: exitSummary.address, location: newValue) }
    }
    @Published var availableUpdate: AppUpdateRelease?
    @Published var showUpdatePrompt = false
    @Published var showUpdateResult = false
    @Published var updateMessage = ""
    @Published var isCheckingUpdate = false
    @Published var isInstallingUpdate = false

    @Published var core = MetricState(title: "代理核心", symbol: CloudSymbols.core, value: "检查中", level: .idle)
    @Published var port = MetricState(title: "本地端口", symbol: CloudSymbols.localPort, value: "检查中", level: .idle)
    @Published var entry = MetricState(title: "流量入口", symbol: CloudSymbols.entryInactive, value: "检查中", level: .idle)
    @Published var killSwitch = MetricState(title: "Kill Switch", symbol: CloudSymbols.killSwitch, value: "检查中", level: .idle)

    var connectionValue: String {
        if let value = connectionStatusPresentation?.value { return value }
        switch overallLevel {
        case .ok: return "代理路径"
        case .warning: return headline
        case .error: return "代理状态不可用"
        case .idle: return "检查中"
        }
    }

    var connectionLevel: HealthLevel {
        if let tone = connectionStatusPresentation?.tone {
            return switch tone {
            case .ok: .ok
            case .warning: .warning
            case .error: .error
            case .idle: .idle
            }
        }
        return overallLevel
    }

    private var connectionPresentation: ConnectionPathPresentation {
        ConnectionPathPresentation.make(mode: discovery.mode)
    }

    private var connectionStatusPresentation: ConnectionStatusPresentation? {
        ConnectionStatusPresentation.make(
            mode: discovery.mode,
            networkAvailable: networkPathSatisfied,
            probeAvailable: discovery.mode != "正在读取" && discovery.mode != "状态不可用"
        )
    }

    var connectionDetail: String {
        if let detail = connectionStatusPresentation?.detailOverride { return detail }
        let endpoint = UserDefaults.standard.string(
            forKey: ProxyGaugePreferences.selectedEndpointKey
        ).flatMap(LocalEndpointPolicy.normalize)
            ?? LocalEndpointPolicy.normalize(discovery.endpoint)
            ?? "127.0.0.1:7890"
        let selectedCore = guardSelection.flatMap { selection in
            selection.ambiguous || selection.path.isEmpty
                ? nil
                : URL(fileURLWithPath: selection.path).lastPathComponent
        }
        return ConnectionDetailFormatter.format(
            client: guardSelection?.detectedClientName ?? discovery.client,
            core: selectedCore ?? discovery.core,
            endpoint: endpoint,
            mode: discovery.mode,
            discoveryFound: discovery.found,
            discoveryActive: discovery.active,
            coreHealthy: core.level == .ok,
            portHealthy: port.level == .ok,
            entryTitle: entry.title,
            entryValue: entry.value,
            entryHealthy: entry.level == .ok
        )
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private let updateService = AppUpdateService()
    private let exitSummaryService: any ExitSummaryResolving
    private var refreshGeneration = RefreshGenerationGate()
    private var discoveryGeneration = RefreshGenerationGate()
    private var refreshQueued = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "com.valenlan.proxygauge.network-path")
    private var receivedInitialNetworkPath = false
    @Published private var networkPathSatisfied: Bool?
    private var activeRefreshTask: Task<Void, Never>?
    private var activeExitRefreshTask: Task<ExitSummarySnapshot, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var pathEvaluationTask: Task<Void, Never>?
    private var exitRefreshGeneration = RefreshGenerationGate()
    private var observedPathFingerprint: String?
    private var needsExitRefreshWhenActive = false
    private var systemNetworkChangeMonitor: SystemNetworkChangeMonitor?

    private let backendPath = Bundle.main.path(forResource: "proxygauge-backend", ofType: "sh")

    init(
        startImmediately: Bool = true,
        exitSummaryService: any ExitSummaryResolving = SystemExitSummaryService()
    ) {
        self.exitSummaryService = exitSummaryService
        guard startImmediately else { return }
        startNetworkMonitoring()
        startSystemNetworkMonitoring()
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.evaluateCurrentPathChange(isStartup: true)
            let defaults = UserDefaults.standard
            let setupCompleted = defaults.bool(forKey: ProxyGaugePreferences.setupCompletedKey)
            let savedEndpointIsValid = defaults.string(
                forKey: ProxyGaugePreferences.selectedEndpointKey
            ).flatMap(LocalEndpointPolicy.normalize) != nil
            if setupCompleted && !savedEndpointIsValid {
                defaults.set(false, forKey: ProxyGaugePreferences.setupCompletedKey)
            }
            if (!setupCompleted || !savedEndpointIsValid),
               !Self.hasDetectedSystemPath(self.discovery.mode) {
                await self.discoverConnection(showSheet: true)
            }
            await self.checkForUpdatesIfNeeded()
        }
    }

    deinit {
        activeRefreshTask?.cancel()
        activeExitRefreshTask?.cancel()
        automaticRefreshTask?.cancel()
        pathEvaluationTask?.cancel()
        systemNetworkChangeMonitor?.stop()
        networkMonitor?.cancel()
    }

    func openConnectionSetup() {
        Task { [weak self] in
            await self?.discoverConnection(showSheet: true)
        }
    }

    func discoverConnection(showSheet: Bool = false) async {
        if showSheet {
            showConnectionSetup = true
        }
        guard !isDiscoveringConnection else { return }
        isDiscoveringConnection = true
        let generation = discoveryGeneration.request()

        let result = await execute("discover")
        guard discoveryGeneration.accepts(generation) else {
            isDiscoveringConnection = false
            return
        }
        if result.status == 0 {
            discovery = parseDiscovery(result.output)
        } else {
            let savedEndpoint = UserDefaults.standard.string(
                forKey: ProxyGaugePreferences.selectedEndpointKey
            ).flatMap(LocalEndpointPolicy.normalize) ?? "127.0.0.1:7890"
            discovery = ProxyDiscovery(
                found: false,
                client: "未发现代理客户端",
                core: "",
                endpoint: savedEndpoint,
                mode: "未开启",
                source: "请手动设置",
                active: false
            )
        }
        isDiscoveringConnection = false
    }

    func confirmConnection(endpoint: String) {
        guard let normalizedEndpoint = LocalEndpointPolicy.normalize(endpoint) else { return }
        UserDefaults.standard.set(normalizedEndpoint, forKey: ProxyGaugePreferences.selectedEndpointKey)
        UserDefaults.standard.set(true, forKey: ProxyGaugePreferences.setupCompletedKey)
        showConnectionSetup = false
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func deferConnectionSetup() {
        showConnectionSetup = false
    }

    func refresh() async {
        let requestedGeneration = refreshGeneration.request()
        let requestedDiscoveryGeneration = discoveryGeneration.request()

        if isRefreshing {
            refreshQueued = true
            activeRefreshTask?.cancel()
            await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
            return
        }

        isRefreshing = true
        var generation = requestedGeneration
        var activeDiscoveryGeneration = requestedDiscoveryGeneration
        repeat {
            refreshQueued = false
            let workGeneration = generation
            let workDiscoveryGeneration = activeDiscoveryGeneration
            let work = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performRefresh(
                    generation: workGeneration,
                    discoveryGeneration: workDiscoveryGeneration
                )
            }
            activeRefreshTask = work
            await work.value
            activeRefreshTask = nil
            generation = refreshGeneration.current
            activeDiscoveryGeneration = discoveryGeneration.current
        } while refreshQueued
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func applicationDidBecomeActive() {
        schedulePathEvaluation()
        guard ExitRefreshTriggerPolicy.shouldStartLookup(
            isApplicationActive: true,
            hasPendingPathChange: needsExitRefreshWhenActive
        ) else { return }
        needsExitRefreshWhenActive = false
        scheduleExitRefresh()
    }

    func applicationDidResignActive() {
        if automaticRefreshTask != nil {
            needsExitRefreshWhenActive = true
        }
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    private func performRefresh(generation: UInt64, discoveryGeneration: UInt64) async {
        guardSelection = GuardSelectionSnapshot.read()
        async let probeResult = execute("probe")
        async let discoveryResult = execute("discover")
        let (result, discovered) = await (probeResult, discoveryResult)
        guard refreshGeneration.accepts(generation) else { return }

        if self.discoveryGeneration.accepts(discoveryGeneration) {
            if discovered.status == 0 {
                discovery = parseDiscovery(discovered.output)
            } else {
                discovery = ProxyDiscovery(
                    found: false,
                    client: "未识别",
                    core: "",
                    endpoint: UserDefaults.standard.string(
                        forKey: ProxyGaugePreferences.selectedEndpointKey
                    ).flatMap(LocalEndpointPolicy.normalize) ?? "未配置",
                    mode: "状态不可用",
                    source: "自动检测失败",
                    active: false
                )
            }
        }

        guard result.status == 0 else {
            markProbeUnavailable(
                detail: Self.boundedBackendFailure(result.output)
            )
            return
        }
        applyProbe(result.output)
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isInitialPath = !self.receivedInitialNetworkPath
                self.receivedInitialNetworkPath = true
                self.networkPathSatisfied = isSatisfied
                if !isSatisfied {
                    self.automaticRefreshTask?.cancel()
                    self.invalidateExitSummary(as: .disconnected)
                    if !isInitialPath { self.schedulePathEvaluation() }
                    return
                }
                if !isInitialPath { self.schedulePathEvaluation() }
            }
        }
        monitor.start(queue: networkMonitorQueue)
    }

    private func invalidateExitSummary(as snapshot: ExitSummarySnapshot) {
        _ = exitRefreshGeneration.request()
        if snapshot == .checking { beginExitLoading() } else { finishExitLoading(snapshot) }
        activeExitRefreshTask?.cancel()
    }

    private func startSystemNetworkMonitoring() {
        let monitor = SystemNetworkChangeMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePathEvaluation()
            }
        }
        systemNetworkChangeMonitor = monitor
        monitor.start()
    }

    private func schedulePathEvaluation() {
        pathEvaluationTask?.cancel()
        pathEvaluationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pathEvaluationTask = nil
            await self.evaluateCurrentPathChange(isStartup: false)
        }
    }

    private static func systemProxyFingerprint() -> String {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return "unavailable"
        }
        let relevantKeys = [
            "HTTPEnable", "HTTPProxy", "HTTPPort",
            "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
            "SOCKSEnable", "SOCKSProxy", "SOCKSPort",
            "ProxyAutoConfigEnable", "ProxyAutoConfigURLString",
            "ProxyAutoDiscoveryEnable", "ExceptionsList", "ExcludeSimpleHostnames"
        ]
        let relevantSettings = relevantKeys.reduce(into: [String: Any]()) { result, key in
            if let value = settings[key] {
                result[key] = value
            }
        }
        let digest = SHA256.hash(data: Data(stableDescription(relevantSettings).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func currentPathFingerprint() async -> String? {
        let result = await execute("fingerprint")
        guard result.status == 0 else { return nil }
        let local = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !local.isEmpty else { return nil }
        let material = "proxy=\(Self.systemProxyFingerprint())\nlocal=\(local)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func evaluateCurrentPathChange(isStartup: Bool) async {
        guard let current = await currentPathFingerprint() else { return }
        let previous = observedPathFingerprint ?? ExitSummaryPersistence.loadPathFingerprint()
        observedPathFingerprint = current
        guard let previous else {
            ExitSummaryPersistence.recordPathFingerprint(current, clearSummary: false)
            return
        }
        guard ExitRefreshTriggerPolicy.pathDidChange(previous: previous, current: current) else {
            return
        }

        ExitSummaryPersistence.recordPathFingerprint(current, clearSummary: true)
        invalidateExitSummary(as: networkPathSatisfied == false ? .disconnected : .waitingAfterPathChange)
        guard networkPathSatisfied != false else { return }
        if isStartup || NSApplication.shared.isActive {
            scheduleExitRefresh()
        } else {
            needsExitRefreshWhenActive = true
        }
    }

    private static func stableDescription(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { key in
                "\(key)=\(stableDescription(dictionary[key] as Any))"
            }.joined(separator: "\u{1F}")
        }
        if let dictionary = value as? NSDictionary {
            let bridged = dictionary.reduce(into: [String: Any]()) { result, entry in
                result[String(describing: entry.key)] = entry.value
            }
            return stableDescription(bridged)
        }
        if let array = value as? [Any] {
            return array.map(stableDescription).joined(separator: "\u{1E}")
        }
        if let optional = value as? AnyHashable {
            return String(describing: optional)
        }
        return String(describing: value)
    }

    private static func hasDetectedSystemPath(_ mode: String) -> Bool {
        mode.contains("TUN") || mode.contains("VPN") || mode.contains("系统代理") || mode.contains("PAC")
    }

    private func scheduleExitRefresh() {
        guard NSApplication.shared.isActive else {
            needsExitRefreshWhenActive = true
            return
        }
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.automaticRefreshTask = nil
            guard NSApplication.shared.isActive else {
                self.needsExitRefreshWhenActive = true
                return
            }
            await self.refresh()
            guard !Task.isCancelled, NSApplication.shared.isActive else {
                self.needsExitRefreshWhenActive = true
                return
            }
            await self.refreshExitSummary()
        }
    }

    private func refreshExitSummary() async {
        guard !Task.isCancelled else { return }
        guard networkPathSatisfied != false else {
            invalidateExitSummary(as: .disconnected)
            return
        }
        let generation = exitRefreshGeneration.request()
        beginExitLoading()
        activeExitRefreshTask?.cancel()
        let task = Task { [exitSummaryService] in
            await exitSummaryService.resolve()
        }
        activeExitRefreshTask = task
        let result = await task.value
        guard exitRefreshGeneration.accepts(generation) else { return }
        activeExitRefreshTask = nil
        finishExitLoading(result)
        if PublicIPAddress.normalize(result.address) != nil {
            ExitSummaryPersistence.saveSummary(result)
        }
    }

    @discardableResult
    func checkForUpdates(silent: Bool = false) async -> Bool {
        guard !isCheckingUpdate && !isInstallingUpdate else { return false }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        do {
            if let release = try await updateService.check(currentVersion: currentVersion) {
                availableUpdate = release
                showUpdatePrompt = true
            } else if !silent {
                availableUpdate = nil
                showUpdatePrompt = false
                updateMessage = "当前 v\(currentVersion) 已是最新版。"
                showUpdateResult = true
            } else {
                availableUpdate = nil
                showUpdatePrompt = false
            }
            return true
        } catch {
            if !silent {
                updateMessage = "暂时无法完成更新检查。\n\n\(error.localizedDescription)"
                showUpdateResult = true
            }
            return false
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        busyLabel = "正在下载并校验更新…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let downloaded = try await self.updateService.download(release)
                try await self.updateService.installDownloadedUpdate(
                    release,
                    archive: downloaded.archive,
                    checksum: downloaded.checksum
                )
            } catch {
                self.isInstallingUpdate = false
                self.busyLabel = ""
                self.updateMessage = "更新没有安装。\n\n\(error.localizedDescription)"
                self.showUpdateResult = true
            }
        }
    }

    private func checkForUpdatesIfNeeded() async {
        let key = "proxygauge.lastUpdateCheck.v1"
        let lastCheck = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard UpdateCheckSchedule.shouldCheck(lastSuccessfulCheck: lastCheck) else { return }
        if await checkForUpdates(silent: true) {
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    func runHealthCheck() {
        runAction("health", title: "代理链路检测", busy: "正在检测代理链路…")
    }

    func saveHealthPlan(_ plan: HealthCheckPlan) {
        guard plan.isValid else { return }
        ProxyGaugePreferences.saveHealthPlan(plan)
        healthPlan = ProxyGaugePreferences.loadHealthPlan()
        showHealthPlanSetup = false
    }

    func chooseGuardApplication() {
        enableAfterSelection = killSwitch.level == .ok
        guardSelectionError = ""
        showGuardApplicationSelection = true
        Task { [weak self] in
            guard let self else { return }
            let result = await self.execute("guard-applications")
            self.guardApplications = GuardApplicationPolicy.parseChoices(result.output)
        }
    }

    func chooseOtherGuardApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择正在运行的代理客户端或核心程序"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.execute("guard-applications", arguments: [url.path])
            let choices = GuardApplicationPolicy.parseChoices(result.output)
            guard !choices.isEmpty else { self.guardSelectionError = "没有发现此应用正在运行的核心，请先开启客户端的系统服务。"; return }
            self.guardApplications = choices
        }
    }

    func selectGuardApplication(_ path: String?) {
        if let path {
            guard GuardApplicationPolicy.validPath(path) else { return }
            UserDefaults.standard.set(path, forKey: Self.guardPreferenceKey)
        } else { UserDefaults.standard.removeObject(forKey: Self.guardPreferenceKey) }
        showGuardApplicationSelection = false
        if enableAfterSelection { enableKillSwitch() }
        else { guardSelection = nil }
    }

    func enableKillSwitch() {
        runAction("kill-on", title: "已开启 Kill Switch", busy: "正在开启 Kill Switch…")
    }

    func disableKillSwitch() {
        runAction("kill-off", title: "已关闭 Kill Switch", busy: "正在关闭 Kill Switch…")
    }

    private func runAction(
        _ action: String,
        arguments: [String] = [],
        title: String,
        busy: String
    ) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = busy

        Task { [weak self] in
            guard let self else { return }
            let result = await self.execute(action, arguments: arguments)
            let cleanOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHealth = action == "health"
            let succeeded = result.status == 0 && (!isHealth || !cleanOutput.isEmpty)
            let displayedOutput: String
            if isHealth && cleanOutput.isEmpty {
                displayedOutput = """
                ===== 1. 链路检测脚本 =====
                  ❌ 脚本没有返回文本（退出状态 \(result.status)）
                  ℹ️ 请确认 App 内置脚本可执行，然后重新运行链路检测
                """
            } else if cleanOutput.isEmpty {
                displayedOutput = succeeded ? "操作已完成。" : "没有收到操作结果。"
            } else {
                displayedOutput = cleanOutput
            }
            self.isBusy = false
            self.busyLabel = ""
            if action == "kill-on" && !succeeded && cleanOutput.contains("PROXY_AMBIGUOUS") {
                self.chooseGuardApplication()
                self.enableAfterSelection = true
                return
            }
            self.guardSelection = GuardSelectionSnapshot.read()
            self.resultSheet = ResultSheet(
                kind: isHealth ? .health : .standard,
                title: isHealth ? title : (succeeded ? title : "操作失败"),
                output: displayedOutput,
                success: succeeded,
                status: result.status
            )
            await self.refresh()
        }
    }

    private func applyProbe(_ output: String) {
        guard let parsed = ProbeOutputParser.parse(output),
              let overall = HealthLevel(rawValue: parsed.overallLevel),
              let coreLevel = HealthLevel(rawValue: parsed.core.level),
              let portLevel = HealthLevel(rawValue: parsed.port.level),
              let entryLevel = HealthLevel(rawValue: parsed.entry.level),
              let killSwitchLevel = HealthLevel(rawValue: parsed.killSwitch.level),
              let entryTitle = parsed.entry.title,
              let entrySymbol = parsed.entry.symbol else {
            markProbeUnavailable(detail: "状态检测返回不完整或格式无效，请重新安装或刷新。")
            return
        }

        overallLevel = overall
        headline = parsed.headline
        detail = parsed.detail
        core.value = parsed.core.value
        core.level = coreLevel
        port.value = parsed.port.value
        port.level = portLevel
        entry = MetricState(
            title: entryTitle,
            symbol: entrySymbol,
            value: parsed.entry.value,
            level: entryLevel
        )
        killSwitch.value = parsed.killSwitch.value
        killSwitch.level = killSwitchLevel
    }

    private func parseDiscovery(_ output: String) -> ProxyDiscovery {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }

        let endpoint = LocalEndpointPolicy.normalize(fields["endpoint"] ?? "")
            ?? UserDefaults.standard.string(
                forKey: ProxyGaugePreferences.selectedEndpointKey
            ).flatMap(LocalEndpointPolicy.normalize)
            ?? "127.0.0.1:7890"
        return ProxyDiscovery(
            found: fields["found"] == "1",
            client: fields["client"] ?? "未识别",
            core: fields["core"] ?? "",
            endpoint: endpoint,
            mode: fields["mode"] ?? "未开启",
            source: fields["source"] ?? "手动设置",
            active: fields["active"] == "ok",
            privacy: fields["privacy"] ?? "仅读取本地端口与运行模式，不读取订阅和节点"
        )
    }

    private func markProbeUnavailable(detail message: String) {
        headline = "无法读取状态"
        detail = message
        overallLevel = .error
        core = MetricState(
            title: "代理核心",
            symbol: CloudSymbols.core,
            value: "状态不可用",
            level: .error
        )
        port = MetricState(
            title: "本地端口",
            symbol: CloudSymbols.localPort,
            value: "状态不可用",
            level: .error
        )
        entry = MetricState(
            title: "流量入口",
            symbol: CloudSymbols.entryInactive,
            value: "状态不可用",
            level: .error
        )
        killSwitch = MetricState(
            title: "Kill Switch",
            symbol: CloudSymbols.killSwitch,
            value: "状态不可用",
            level: .error
        )
    }

    private static func boundedBackendFailure(_ rawOutput: String) -> String {
        let normalized = rawOutput
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "后端脚本未响应" }
        return String(normalized.prefix(512))
    }

    private func execute(
        _ action: String,
        arguments: [String] = []
    ) async -> (status: Int32, output: String) {
        if action == "kill-on" || action == "kill-off" {
            return await KillSwitchAdminService.run(
                action: action == "kill-on" ? "on" : "off",
                selection: UserDefaults.standard.string(forKey: Self.guardPreferenceKey) ?? "AUTO"
            )
        }
        guard let path = backendPath else {
            return (1, "应用内缺少状态检测组件，请从正式渠道重新安装。")
        }
        do {
            try BundledResourceIntegrity.validateRegularFile(
                at: URL(fileURLWithPath: path),
                expectedSHA256: BundledResourceIntegrity.backendSHA256
            )
        } catch {
            return (1, error.localizedDescription)
        }
        let healthPlan = healthPlan
        let selectedEndpoint = UserDefaults.standard.string(forKey: ProxyGaugePreferences.selectedEndpointKey)
        let validSelectedEndpoint = selectedEndpoint.flatMap(LocalEndpointPolicy.normalize)
        let timeoutSeconds: TimeInterval?
        if action == "fingerprint" {
            timeoutSeconds = 5
        } else if ["probe", "discover"].contains(action) {
            timeoutSeconds = 15
        } else if action == "health" {
            // The supported 30-second per-request setting can cover nine
            // retried web probes plus three bounded controller reads.
            timeoutSeconds = 15 * 60
        } else {
            timeoutSeconds = nil
        }
        let userName = NSUserName()
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": userName,
            "LOGNAME": userName,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/tmp",
            "LC_ALL": "C"
        ]
        if let validSelectedEndpoint {
            environment["PROXYGAUGE_MIXED"] = validSelectedEndpoint
        }
        if GuardRuntimeState.isTrustedEnabled(),
           let tunnels = GuardSelectionSnapshot.read()?.trustedMihomoTunnels {
            environment["PROXYGAUGE_TRUSTED_MIHOMO_TUNS"] = tunnels.joined(separator: " ")
        }
        environment["PROXYGAUGE_SECONDARY_ENABLED"] = healthPlan.secondaryEnabled ? "1" : "0"
        environment["PROXYGAUGE_SECONDARY_LABEL"] = healthPlan.secondaryLabel
        environment["PROXYGAUGE_SECONDARY_GROUP"] = healthPlan.secondaryGroup
        environment["PROXYGAUGE_DEFAULT_GROUP"] = healthPlan.defaultGroup
        environment["PROXYGAUGE_SECONDARY_MIXED"] = healthPlan.secondaryEndpoint
        environment["PROXYGAUGE_SECONDARY_DOMAINS"] = healthPlan.normalizedDomains.joined(separator: ",")
        return await BackendCommandRunner.run(
            scriptPath: path,
            action: action,
            arguments: arguments,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }
}

enum AppThemePalette {
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(dark: UInt32, light: NSColor) -> Color {
        let darkColor = rgb(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : light
        })
    }

    static let canvas = adaptive(dark: 0x181A1C, light: .white)
    static let surface = adaptive(dark: 0x202324, light: .controlBackgroundColor)
    static let raisedSurface = adaptive(dark: 0x25292A, light: .controlBackgroundColor)
    static let border = adaptive(dark: 0x343A38, light: .separatorColor)
    static let text = adaptive(dark: 0xE7EAE9, light: .labelColor)
    static let secondaryText = adaptive(dark: 0x989E9B, light: .secondaryLabelColor)
    static let tertiaryText = adaptive(dark: 0x626866, light: .tertiaryLabelColor)
    static let accent = adaptive(dark: 0x36EC8F, light: .systemBlue)
    static let onAccent = adaptive(dark: 0x0D1712, light: .white)
    static let statusGreen = adaptive(
        dark: 0x36EC8F,
        light: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    )
}

private enum CloudPalette {
    static let statusGreen = AppThemePalette.statusGreen
    static let statusGray = Color.secondary
    static let statusOrange = Color.orange
    static let statusRed = Color.red
    static let networkBlue = Color(red: 0.13, green: 0.55, blue: 1.00)
    static let googleViolet = Color(red: 0.61, green: 0.48, blue: 1.00)
    static let reviewCyan = Color(red: 0.20, green: 0.72, blue: 0.82)
    static let rulesViolet = Color(red: 0.54, green: 0.42, blue: 0.96)
}

private enum CloudSymbols {
    static let core = "cpu"
    static let localPort = "cable.connector.horizontal"
    static let entryInactive = "arrow.triangle.branch"
    static let killSwitch = "shield"
    static let health = "waveform.path.ecg"
    static let advanced = "scope"
    static let rules = "list.bullet.rectangle"
    static let connectionSettings = "slider.horizontal.3"
    static let refresh = "arrow.clockwise"
    static let plan = "slider.horizontal.3"
    static let run = "play.fill"
    static let open = "arrow.up.right"
    static let manage = "chevron.right"
}

enum MainWindowLayout {
    // Keep the dashboard legible at its smallest size. The window itself may
    // grow or enter full screen while the dashboard remains width-constrained.
    static let minimumWidth: CGFloat = 760
    static let minimumContentHeight: CGFloat = 500
    static let defaultWidth: CGFloat = 820
    static let defaultHeight: CGFloat = 500
}

enum CloudTypography {
    static let headline = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let headerDetail = Font.system(size: 12)
    static let metricLabel = Font.system(size: 11, weight: .medium)
    static func metricValue(monospaced: Bool = false) -> Font {
        .system(size: 18, weight: .semibold, design: monospaced ? .monospaced : .rounded)
    }
    static let actionTitle = Font.system(size: 14, weight: .semibold)
    static let actionDetail = Font.system(size: 10.5)
}

private struct CloudSymbolGlyph: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    var weight: Font.Weight = .medium
    var frameSize: CGFloat? = nil

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
            .frame(width: frameSize ?? size + 4, height: frameSize ?? size + 4)
            .accessibilityHidden(true)
    }
}

private struct CloudIconBadge: View {
    let symbol: String
    let tint: Color
    let containerSize: CGFloat
    let cornerRadius: CGFloat
    let glyphSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.14))
            CloudSymbolGlyph(
                symbol: symbol,
                tint: tint,
                size: glyphSize,
                frameSize: glyphSize + 4
            )
        }
        .frame(width: containerSize, height: containerSize)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 1)
        }
    }
}

struct MetricCard: View {
    let metric: MetricState

    private var iconColor: Color {
        metric.level.color
    }

    var body: some View {
        HStack(spacing: 13) {
            CloudIconBadge(
                symbol: metric.symbol,
                tint: iconColor,
                containerSize: 38,
                cornerRadius: 11,
                glyphSize: 16
            )

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
        case .ok: return CloudPalette.statusGreen
        case .idle: return CloudPalette.statusGray
        }
    }

    private var isUnconfigured: Bool {
        metric.value == "未配置"
    }

    private var isChecking: Bool {
        metric.value == "检查中"
    }

    var body: some View {
        HStack(spacing: 13) {
            CloudIconBadge(
                symbol: CloudSymbols.killSwitch,
                tint: iconColor,
                containerSize: 38,
                cornerRadius: 11,
                glyphSize: 16
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Kill Switch")
                    .font(CloudTypography.metricLabel)
                    .foregroundStyle(.secondary)
                Text(isUnconfigured ? "未开启" : metric.value)
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
            .disabled(isBusy || isChecking)
            .help(
                metric.level == .ok ? "关闭防泄漏保护" : "开启防泄漏保护"
            )
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

struct HealthReport {
    let checkedAt: String?
    let planName: String
    let secondaryEnabled: Bool
    let sections: [HealthCheckSection]
    let passCount: Int
    let warningCount: Int
    let failCount: Int

    private static let standardWeights: [String: Double] = [
        "1": 25,
        "2": 25,
        "3": 25,
        "4": 25
    ]

    private static let extendedWeights: [String: Double] = [
        "1": 15,
        "2": 15,
        "3": 15,
        "4": 20,
        "5": 15,
        "6": 5,
        "7": 15
    ]

    var score: Int {
        var earned = 0.0
        let sectionWeights = secondaryEnabled ? Self.extendedWeights : Self.standardWeights
        for section in sections {
            guard let weight = sectionWeights[section.number] else { continue }
            if section.hasFailure {
                continue
            }
            earned += section.hasWarning ? weight * 0.5 : weight
        }

        var value = Int(earned.rounded())
        if sections.contains(where: { ["1", "2", "3", "4"].contains($0.number) && $0.hasFailure }) {
            value = min(value, 49)
        } else if sections.contains(where: { sectionWeights[$0.number] != nil && $0.hasFailure }) {
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
        var detectedPlan = "通用检测"
        var hasSecondary = false
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

            if line.hasPrefix("检测方案:") {
                detectedPlan = line.replacingOccurrences(of: "检测方案:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            if line == "额外分流: 1" {
                hasSecondary = true
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
        planName = detectedPlan
        secondaryEnabled = hasSecondary
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

    private var healthExecutionIncomplete: Bool {
        result.status == BackendCommandRunner.timeoutStatus ||
            result.status == BackendCommandRunner.cancelledStatus ||
            (result.status != 0 && report.failCount == 0)
    }

    private var displayedHealthScore: Int {
        healthExecutionIncomplete ? min(report.score, 49) : report.score
    }

    private var displayedHealthScoreLabel: String {
        healthExecutionIncomplete ? "未完成" : report.scoreLabel
    }

    private var healthColor: Color {
        if healthExecutionIncomplete || report.failCount > 0 || (!result.success && report.sections.isEmpty) {
            return Color(red: 0.91, green: 0.31, blue: 0.29)
        }
        if report.warningCount > 0 { return .orange }
        return Color(red: 0.17, green: 0.66, blue: 0.43)
    }

    private var healthTitle: String {
        if report.sections.isEmpty { return "未收到检查详情" }
        if healthExecutionIncomplete { return "检测未完成" }
        if report.failCount > 0 { return "发现 \(report.failCount) 项问题" }
        if report.warningCount > 0 { return "网络可用，仍有 \(report.warningCount) 项提示" }
        return "网络检测通过"
    }

    private var scoreColor: Color {
        if healthExecutionIncomplete { return Color(red: 0.91, green: 0.31, blue: 0.29) }
        if displayedHealthScore >= 90 { return Color(red: 0.17, green: 0.66, blue: 0.43) }
        if displayedHealthScore >= 50 { return .orange }
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
                            .trim(from: 0, to: Double(displayedHealthScore) / 100)
                            .stroke(scoreColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(displayedHealthScore)")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreColor)
                    }
                    .frame(width: 50, height: 50)
                    Text("链路分 · \(displayedHealthScoreLabel)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(scoreColor)
                }
            }

            HStack(spacing: 8) {
                Label("\(report.planName) · IP 纯净度复核不计分", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                summaryBadge("\(report.passCount) 通过", color: Color(red: 0.17, green: 0.66, blue: 0.43))
                if report.warningCount > 0 {
                    summaryBadge("\(report.warningCount) 提示", color: .orange)
                }
                summaryBadge("\(report.failCount) 失败", color: report.failCount == 0 ? .secondary : healthColor)
            }

            if healthExecutionIncomplete {
                Label("检测进程未完整结束；以下仅为已返回的部分结果。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthColor)
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
                    Text("链路检测没有返回可解析的项目。请关闭弹窗后重新运行；如果反复出现，请检查本地脚本。")
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
        return !output.isEmpty && output != "操作已完成。" && !output.hasPrefix("链路检测没有返回详情")
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
            copiedOutput = "链路分：\(report.score)/100 · \(report.scoreLabel)\n\(copiedOutput)"
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
                    CloudIconBadge(
                        symbol: symbol,
                        tint: tint,
                        containerSize: 30,
                        cornerRadius: 15,
                        glyphSize: 13
                    )

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
                            CloudSymbolGlyph(
                                symbol: actionSymbol,
                                tint: tint,
                                size: 10,
                                weight: .semibold,
                                frameSize: 12
                            )
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

private struct HealthActionCard: View {
    let plan: HealthCheckPlan
    let isRunning: Bool
    let isDisabled: Bool
    let openPlan: () -> Void
    let run: () -> Void

    @State private var isHovering = false

    private var scopeLabels: [String] {
        if plan.secondaryEnabled {
            return ["基础链路", "出口一致", "\(plan.secondaryLabel) 分流"]
        }
        return ["代理核心", "流量入口", "出口一致"]
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 9) {
                CloudIconBadge(
                    symbol: CloudSymbols.health,
                    tint: CloudPalette.networkBlue,
                    containerSize: 30,
                    cornerRadius: 15,
                    glyphSize: 13
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("链路检测")
                        .font(CloudTypography.actionTitle)
                    Text(isRunning ? "正在按方案检测…" : "按当前方案检查连接")
                        .font(CloudTypography.actionDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(2)

                Text(scopeLabels.joined(separator: "  ·  "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 12)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button(action: openPlan) {
                        HStack(spacing: 5) {
                            CloudSymbolGlyph(
                                symbol: CloudSymbols.plan,
                                tint: CloudPalette.networkBlue,
                                size: 10,
                                weight: .medium,
                                frameSize: 13
                            )
                            Text("方案")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CloudPalette.networkBlue)
                        .frame(width: 76, height: 28)
                        .background(
                            CloudPalette.networkBlue.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(CloudPalette.networkBlue.opacity(0.34), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .allowsHitTesting(!isDisabled)
                    .opacity(isDisabled ? 0.48 : 1)
                    .help("调整链路检测方案")

                    Button(action: run) {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(CloudPalette.networkBlue)
                            } else {
                                CloudSymbolGlyph(
                                    symbol: CloudSymbols.run,
                                    tint: CloudPalette.networkBlue,
                                    size: 10,
                                    weight: .semibold,
                                    frameSize: 13
                                )
                            }
                            Text(isRunning ? "检测中" : "检测")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CloudPalette.networkBlue)
                        .frame(width: 76, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(CloudPalette.networkBlue.opacity(isHovering ? 0.24 : 0.14))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    CloudPalette.networkBlue.opacity(isHovering ? 0.58 : 0.30),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.borderless)
                    .allowsHitTesting(!isDisabled)
                    .help(isRunning ? "正在检测代理链路" : "按当前方案检测代理链路")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(CloudPalette.networkBlue)
                    .controlSize(.small)
                    .accessibilityLabel("链路检测正在运行")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            isHovering && !isDisabled
                ? CloudPalette.networkBlue.opacity(0.055)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isHovering && !isDisabled
                        ? CloudPalette.networkBlue.opacity(0.32)
                        : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        }
        .opacity(isDisabled && !isRunning ? 0.58 : 1)
        .accessibilityValue(isRunning ? "正在运行" : "")
        .accessibilityElement(children: .contain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

struct RulePackCard: View {
    let action: () -> Void

    var body: some View {
        DashboardActionCard(
            title: "规则管理",
            detail: "12 条 · 2026.08",
            symbol: CloudSymbols.rules,
            actionLabel: "管理",
            actionSymbol: CloudSymbols.manage,
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
                CloudIconBadge(
                    symbol: CloudSymbols.rules,
                    tint: CloudPalette.rulesViolet,
                    containerSize: 50,
                    cornerRadius: 14,
                    glyphSize: 20
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("ProxyGauge 规则包")
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
        Bundle.main.url(forResource: "ProxyGauge-Merge", withExtension: "yaml", subdirectory: "Rules")
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
        panel.title = "导出 ProxyGauge 规则包"
        panel.nameFieldStringValue = "ProxyGauge-Merge.yaml"
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

private struct HealthPlanSetupView: View {
    let save: (HealthCheckPlan) -> Void
    let close: () -> Void

    @State private var draft: HealthCheckPlan

    init(plan: HealthCheckPlan, save: @escaping (HealthCheckPlan) -> Void, close: @escaping () -> Void) {
        self.save = save
        self.close = close
        _draft = State(initialValue: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(CloudPalette.networkBlue.opacity(0.14))
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(CloudPalette.networkBlue)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("链路检测方案")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("基础连接始终检测；额外出口和规则按你的代理结构启用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                planStage(
                    symbol: "network",
                    title: "基础连接",
                    detail: "核心 · 入口 · 出口一致",
                    tint: CloudPalette.networkBlue,
                    active: true
                )
                Rectangle()
                    .fill((draft.secondaryEnabled ? CloudPalette.googleViolet : CloudPalette.statusGray).opacity(0.38))
                    .frame(height: 2)
                planStage(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "额外分流",
                    detail: draft.secondaryEnabled ? draft.secondaryLabel : "未启用",
                    tint: CloudPalette.googleViolet,
                    active: draft.secondaryEnabled
                )
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 13) {
                Toggle(isOn: $draft.secondaryEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("检测额外出口与域名规则")
                            .font(.system(size: 13, weight: .semibold))
                        Text("适合双出口、链式代理或指定域名分流；普通单出口可以关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(CloudPalette.googleViolet)

                Divider()

                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) {
                        field("方案名称", text: $draft.secondaryLabel, placeholder: "Google / Gemini / Claude")
                        field("目标策略组", text: $draft.secondaryGroup, placeholder: "Google-Chain")
                    }

                    HStack(spacing: 12) {
                        field("默认策略组", text: $draft.defaultGroup, placeholder: "PROXY")
                        field("额外本地入口", text: $draft.secondaryEndpoint, placeholder: "127.0.0.1:7891")
                    }

                    field(
                        "应命中目标策略组的域名（逗号分隔，最多 8 个）",
                        text: $draft.secondaryDomains,
                        placeholder: "gemini.google.com, claude.ai, api.anthropic.com"
                    )
                }
                .disabled(!draft.secondaryEnabled)
                .opacity(draft.secondaryEnabled ? 1 : 0.46)
            }

            HStack(spacing: 8) {
                Label("不读取节点、订阅或凭据，只核对运行中的策略组、规则和本地入口。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复当前模板") {
                    draft = .currentTemplate
                    draft.secondaryEnabled = true
                }
                .controlSize(.small)
            }

            HStack {
                if draft.secondaryEnabled && !draft.isValid {
                    Text("请检查策略组、本地回环入口和域名格式。")
                        .font(.caption)
                        .foregroundStyle(CloudPalette.statusRed)
                }
                Spacer()
                Button("取消", action: close)
                    .controlSize(.small)
                Button("保存方案") { save(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid)
            }
        }
        .padding(22)
        .frame(width: 570, height: 520)
        .interactiveDismissDisabled()
    }

    private func planStage(symbol: String, title: String, detail: String, tint: Color, active: Bool) -> some View {
        let color = active ? tint : CloudPalette.statusGray
        return HStack(spacing: 9) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConnectionSetupView: View {
    let discovery: ProxyDiscovery
    let isDiscovering: Bool
    let confirm: (String) -> Void
    let redetect: () -> Void

    @State private var manualMode = false
    @State private var manualPort = "7890"

    private var parsedPort: Int? {
        guard let port = Int(manualPort), (1...65535).contains(port) else { return nil }
        return port
    }

    private var modeColor: Color {
        switch discovery.mode {
        case "TUN", "系统代理": return CloudPalette.statusGreen
        case "双重入口", "系统代理 + 其他 VPN / TUN",
             "PAC / 自动代理 + Mihomo TUN", "系统代理路径 + Mihomo TUN":
            return CloudPalette.statusOrange
        default: return CloudPalette.statusGray
        }
    }

    private var modeSymbol: String {
        switch discovery.mode {
        case "TUN": return "arrow.triangle.2.circlepath"
        case "系统代理": return "network"
        case "双重入口", "系统代理 + 其他 VPN / TUN",
             "PAC / 自动代理 + Mihomo TUN", "系统代理路径 + Mihomo TUN":
            return "exclamationmark.triangle.fill"
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
                         ? "确认一次即可开始使用 ProxyGauge。"
                         : "启动 Clash Verge 或 Mihomo，ProxyGauge 会自动识别。")
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var singletonLockFD: Int32 = -1
    private var ownsSingletonLock = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("com.valenlan.proxygauge.lock")
        singletonLockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard singletonLockFD >= 0,
              flock(singletonLockFD, LOCK_EX | LOCK_NB) == 0 else {
            if singletonLockFD >= 0 {
                Darwin.close(singletonLockFD)
                singletonLockFD = -1
            }

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let existing = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.valenlan.proxygauge"
            )
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
        guard let iconURL = Bundle.main.url(forResource: "ProxyGauge", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendCommandRunner.cancelAll()
        if singletonLockFD >= 0 {
            flock(singletonLockFD, LOCK_UN)
            Darwin.close(singletonLockFD)
        }
        singletonLockFD = -1
    }
}

#if !SNAPSHOT
@main
struct ProxyGaugeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ProxyModel()

    var body: some Scene {
        Window("ProxyGauge", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(
            width: MainWindowLayout.defaultWidth,
            height: MainWindowLayout.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { await model.checkForUpdates() }
                }
                .disabled(model.isCheckingUpdate || model.isInstallingUpdate)

                Divider()

                Button("连接设置…") {
                    model.openConnectionSetup()
                }
            }
        }
    }
}
#endif
