#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(/usr/bin/dirname "$0")
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && /bin/pwd)
APP_SOURCE="$PROJECT_ROOT/Sources/ProxyGaugeApp.swift"
DASHBOARD_SOURCE="$PROJECT_ROOT/Sources/DashboardView.swift"
EXIT_SERVICE="$PROJECT_ROOT/Sources/ExitSummaryService.swift"
CONNECTION_FORMATTER="$PROJECT_ROOT/Sources/ConnectionDetailFormatter.swift"
WINDOWS_MAIN="$PROJECT_ROOT/Windows/MainWindow.xaml"
BACKEND="$PROJECT_ROOT/Scripts/proxygauge-backend.sh"
TEMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/proxygauge-ip-version-test.XXXXXX")
/bin/mkdir -p "$TEMP_ROOT/module-cache"
cleanup() {
  /bin/rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

for label in '监控代理连接、出口 IP 与浏览器隐私' '代理状态' '断网保护' 'IP 纯净度' '隐私泄露' '浏览器测速'; do
  /usr/bin/grep -Fq "$label" "$DASHBOARD_SOURCE"
  /usr/bin/grep -Fq "$label" "$WINDOWS_MAIN"
done
/usr/bin/grep -Fq '系统实际出口' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'x:Name="ExitCardTitle" Text="系统实际出口"' "$WINDOWS_MAIN"

/usr/bin/grep -Fq '@AppStorage("proxygauge.appearance.v1")' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.preferredColorScheme(appearance == "dark" ? .dark : .light)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'ThemeButton_Click' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'ThemeSunIcon' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'ThemeMoonIcon' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'symbol: appearance == "dark" ? "moon.fill" : "sun.max.fill"' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'ThemeSunIcon.Visibility = isDark ? Visibility.Collapsed : Visibility.Visible;' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'ThemeMoonIcon.Visibility = isDark ? Visibility.Visible : Visibility.Collapsed;' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'CopyExitButton_Click' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'x:Name="CopyExitButton" Grid.Row="0" Style="{StaticResource HeaderIconButtonStyle}" Foreground="{DynamicResource MutedTextBrush}"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'ExitClipboard.copy(model.exitAddress)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'copiedExitAddress ? "checkmark" : "doc.on.doc"' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'copyFeedbackTask?.cancel()' "$DASHBOARD_SOURCE"
if /usr/bin/grep -Fq 'model.exitAddress == copiedAddress' "$DASHBOARD_SOURCE"; then
  echo 'Copy feedback must reset even when the exit address changes during its timer.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'tint: AppThemePalette.secondaryText' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'HStack(spacing: 6)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'ExitChip(model.exitLocation)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'IPAddressVersion.parse(model.exitAddress)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'ExitChip(ipVersion.rawValue)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'x:Name="ExitLocationChip" Text="{Binding ExitLocation}"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'VerticalScrollBarVisibility="Hidden"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'struct CuteDashboardIcon: View' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'private struct CuteGlyph: View' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'case .protection:' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'BubblePromptView(' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'BubbleOverlay(dismissOnBackdrop: model.deferConnectionSetup)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'dismissOnBackdrop?()' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'primaryTitle: "继续打开"' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'ProxyGauge 不会读取或保存页面内容。' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.font(CloudTypography.metricLabel)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.font(CloudTypography.metricValue(monospaced: true))' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.font(CloudTypography.actionTitle)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.font(CloudTypography.actionDetail)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.frame(maxWidth: 920)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'AdaptiveToolCardLayout(spacing: 12, horizontalBreakpoint: 650)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'minHeight: geometry.size.height' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'MainWindowCapabilityReader()' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'static let minimumWidth: CGFloat = 760' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let minimumContentHeight: CGFloat = 500' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let defaultHeight: CGFloat = 500' "$APP_SOURCE"
/usr/bin/grep -Fq '.windowResizability(.contentMinSize)' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let canvas = adaptive(dark: 0x181A1C' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let surface = adaptive(dark: 0x202324' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let text = adaptive(dark: 0xE7EAE9' "$APP_SOURCE"
/usr/bin/grep -Fq 'static let accent = adaptive(dark: 0x36EC8F' "$APP_SOURCE"
/usr/bin/grep -Fq '.background(AppThemePalette.canvas.ignoresSafeArea())' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.tint(AppThemePalette.accent)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'Click="GuardButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'if model.guardSelection?.ambiguous == true {' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'guardSelection?.ambiguous == true ? "选择当前代理" : ""' "$APP_SOURCE"
/usr/bin/grep -Fq 'Visibility="{Binding ShowGuardApplicationAction, Converter={StaticResource BooleanToVisibilityConverter}}"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'public bool ShowGuardApplicationAction => GuardEnabled && _guardStatus.SelectionRequired;' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
if /usr/bin/grep -Fq '"切换代理"' "$APP_SOURCE" "$DASHBOARD_SOURCE" "$WINDOWS_MAIN" "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"; then
  echo 'The Guard card must not show a routine switch-proxy subtitle.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'x:Name="ExitCardTitle" Text="系统实际出口" FontSize="11" FontWeight="Medium"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'FontSize="18" FontWeight="SemiBold" Margin="0,8,0,0"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Text="IP 纯净度" FontSize="14" FontWeight="SemiBold"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="IpPurityButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="PrivacyButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="SpeedButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'https://speed.cloudflare.com/' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'await exitSummaryService.resolve()' "$APP_SOURCE"
/usr/bin/grep -Fq 'NWPathMonitor()' "$APP_SOURCE"
/usr/bin/grep -Fq 'refreshGeneration.accepts(generation)' "$APP_SOURCE"
/usr/bin/grep -Fq 'exitRefreshGeneration.accepts(generation)' "$APP_SOURCE"
/usr/bin/grep -Fq 'NSApplication.didBecomeActiveNotification' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'NSApplication.didResignActiveNotification' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'Text("系统实际出口")' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'URLSessionConfiguration.ephemeral' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'configuration.urlCache = nil' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'withTaskGroup(' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'https://ipwho.is/?fields=success,ip,country,country_code,region,city' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'let session = URLSession(' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'CFNetworkCopySystemProxySettings()' "$APP_SOURCE"
/usr/bin/grep -Fq 'SHA256.hash(data: Data(stableDescription(relevantSettings).utf8))' "$APP_SOURCE"
/usr/bin/grep -Fq 'self.automaticRefreshTask = nil' "$APP_SOURCE"
/usr/bin/grep -Fq 'guard NSApplication.shared.isActive else {' "$APP_SOURCE"
/usr/bin/grep -Fq 'automaticRefreshTask?.cancel()' "$APP_SOURCE"
/usr/bin/grep -Fq '!Self.hasDetectedSystemPath(self.discovery.mode)' "$APP_SOURCE"
/usr/bin/grep -Fq 'timeoutSeconds = 15 * 60' "$APP_SOURCE"
/usr/bin/grep -Fq 'let result = await execute("fingerprint")' "$APP_SOURCE"
/usr/bin/grep -Fq 'SystemNetworkChangeMonitor' "$APP_SOURCE"
/usr/bin/grep -Fq 'SCDynamicStoreSetNotificationKeys' "$APP_SOURCE"
/usr/bin/grep -Fq 'ExitSummaryPersistence.loadSummary()' "$APP_SOURCE"
/usr/bin/grep -Fq 'func refreshExitSummary() async' "$APP_SOURCE"
if /usr/bin/grep -Fq 'startPeriodicRefresh' "$APP_SOURCE"; then
  echo 'Opening the dashboard must not start a periodic public-exit lookup loop.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'BackendCommandRunner.run(' "$APP_SOURCE"
/usr/bin/grep -Fq 'KillSwitchAdminService.run(' "$APP_SOURCE"
/usr/bin/grep -Fq 'BundledResourceIntegrity.validateRegularFile(' "$APP_SOURCE"
/usr/bin/grep -Fq '"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"' "$APP_SOURCE"
if /usr/bin/grep -Fq 'ProcessInfo.processInfo.environment' "$APP_SOURCE"; then
  echo 'The app must not forward ambient process variables into bundled shell commands.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'session.bytes(for: request)' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'ExitSummaryRedirectDelegate' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'if healthExecutionIncomplete { return "检测未完成" }' "$APP_SOURCE"
/usr/bin/grep -Fq 'healthExecutionIncomplete ? min(report.score, 49) : report.score' "$APP_SOURCE"
/usr/bin/grep -Fq '检测进程未完整结束；以下仅为已返回的部分结果。' "$APP_SOURCE"
/usr/bin/grep -Fq 'source: "自动检测失败"' "$PROJECT_ROOT/Sources/AppStatePolicies.swift"
/usr/bin/grep -Fq 'DiscoveryResultPolicy.make(' "$APP_SOURCE"
/usr/bin/grep -Fq 'markProbeUnavailable(' "$APP_SOURCE"
/usr/bin/grep -Fq 'parseDiscovery(result.output, status: result.status)' "$APP_SOURCE"
/usr/bin/grep -Fq 'parseDiscovery(discovered.output, status: discovered.status)' "$APP_SOURCE"
/usr/bin/grep -Fq 'if await checkForUpdates(silent: true)' "$APP_SOURCE"
/usr/bin/grep -Fq '"其他 VPN 已连接"' "$CONNECTION_FORMATTER"
/usr/bin/grep -Fq '"其他 VPN / 代理已连接"' "$CONNECTION_FORMATTER"
/usr/bin/grep -Fq '"其他系统代理已启用"' "$CONNECTION_FORMATTER"
connection_detail_binding=$(/usr/bin/sed -n '/^    var connectionDetail: String {/,/^    var currentVersion: String {/p' "$APP_SOURCE")
if /usr/bin/grep -Eq 'guardSelection|selectedCore' <<< "$connection_detail_binding"; then
  echo 'The proxy status subtitle must use current discovery, not the Guard application selection.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'client: discovery.client,' <<< "$connection_detail_binding"
/usr/bin/grep -Fq 'core: discovery.core,' <<< "$connection_detail_binding"
/usr/bin/grep -Fq '未发现代理客户端或核心' "$PROJECT_ROOT/Scripts/proxygauge-check.sh"
/usr/bin/grep -Fq '未发现代理客户端或核心' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq '"无网络连接"' "$PROJECT_ROOT/Sources/AppStatePolicies.swift"
/usr/bin/grep -Fq '"当前使用直连网络"' "$PROJECT_ROOT/Sources/AppStatePolicies.swift"
/usr/bin/grep -Fq 'model.connectionLevel.color' "$DASHBOARD_SOURCE"

if /usr/bin/grep -Eq 'exitNetwork(Type)?|ExitNetwork(Type)?|IP 类型未知|ASN 未知|IP 风险与类型' "$APP_SOURCE" "$DASHBOARD_SOURCE" "$WINDOWS_MAIN"; then
  echo 'The exit card must not restore ASN or IP network-type fields.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'Text("ProxyGauge")' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'x:Name="ProductTitle" Text="ProxyGauge"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'window.titleVisibility = .hidden' "$PROJECT_ROOT/Sources/WindowCapability.swift"
/usr/bin/grep -Fq 'window.titlebarAppearsTransparent = true' "$PROJECT_ROOT/Sources/WindowCapability.swift"
/usr/bin/grep -Fq 'window.titlebarSeparatorStyle = .none' "$PROJECT_ROOT/Sources/WindowCapability.swift"
/usr/bin/grep -Fq '.fullSizeContentView' "$PROJECT_ROOT/Sources/WindowCapability.swift"
/usr/bin/grep -Fq 'static let canvas = adaptive(dark: 0x181A1C, light: .white)' "$APP_SOURCE"

if /usr/bin/grep -Fq 'Text("链路检测")' "$DASHBOARD_SOURCE" \
  || /usr/bin/grep -Fq 'Text("规则管理")' "$DASHBOARD_SOURCE" \
  || /usr/bin/grep -Fq 'MetricCard(metric:' "$DASHBOARD_SOURCE"; then
  echo 'The active dashboard must not expose the removed diagnostics or old metric grid.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'kill-pause|暂停[[:space:]]*10[[:space:]]*分钟' "$APP_SOURCE"; then
  echo 'Disconnect protection must remain a persistent on/off switch.' >&2
  exit 1
fi

if /usr/bin/grep -Fq '.windowResizability(.contentSize)' "$APP_SOURCE" \
  || /usr/bin/grep -Fq 'static let maximumWidth:' "$APP_SOURCE" \
  || /usr/bin/grep -Fq 'static let maximumContentHeight:' "$APP_SOURCE"; then
  echo 'The main macOS window must allow full screen without stretching dashboard content.' >&2
  exit 1
fi

if /usr/bin/grep -Eq '\.alert\(|\.sheet\(' "$DASHBOARD_SOURCE"; then
  echo 'The dashboard must use the shared bubble popup instead of system alerts or sheets.' >&2
  exit 1
fi

if /usr/bin/grep -Fq 'Button("稍后", action: deferSetup)' "$APP_SOURCE"; then
  echo 'The connection bubble must close from its backdrop instead of a Later button.' >&2
  exit 1
fi

/usr/bin/grep -Fq '启动代理客户端（如 Shadowrocket、Clash Verge、Mihomo），ProxyGauge 会自动识别。' "$APP_SOURCE"
if /usr/bin/grep -Fq '启动 Clash Verge 或 Mihomo' "$APP_SOURCE"; then
  echo 'The connection setup guide must address generic proxy clients, not only Clash Verge or Mihomo.' >&2
  exit 1
fi

if /usr/bin/grep -Fq '普通公网' \
  "$APP_SOURCE" "$DASHBOARD_SOURCE" "$WINDOWS_MAIN" \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs" \
  "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"; then
  echo 'The exit card must never infer a generic public network type.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'api\.ipapi\.is/\?q=|PROXYGAUGE_EXIT_DETAIL_JSON|printf .network\\t' "$BACKEND"; then
  echo 'The local IPv4/IPv6 label must not add an IP network-type request.' >&2
  exit 1
fi

/usr/bin/grep -Fq 'attr_name="${engine_name:-当前代理客户端}"' "$BACKEND"
/usr/bin/grep -Fq 'detail="${engine_name} VPN 的可用公网路由已确认"' "$BACKEND"
/usr/bin/grep -Fq 'detail="系统代理与 ${engine_name} VPN 均已启用"' "$BACKEND"
/usr/bin/grep -Fq '不能归因于 ${attr_name}' "$BACKEND"

/usr/bin/grep -Fq 'await withCheckedContinuation' "$APP_SOURCE"
/usr/bin/grep -Fq 'waiter.resume()' "$APP_SOURCE"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/IPAddressVersion.swift" \
  "$PROJECT_ROOT/Tests/IPAddressVersionCheck.swift" \
  -o "$TEMP_ROOT/ip-address-version-check"
"$TEMP_ROOT/ip-address-version-check"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Tests/LocalEndpointPolicyCheck.swift" \
  -o "$TEMP_ROOT/local-endpoint-policy-check"
"$TEMP_ROOT/local-endpoint-policy-check"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/ExitSummaryService.swift" \
  "$PROJECT_ROOT/Tests/ExitSummaryServiceCheck.swift" \
  -o "$TEMP_ROOT/exit-summary-service-check"
"$TEMP_ROOT/exit-summary-service-check"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/BackendCommandRunner.swift" \
  "$PROJECT_ROOT/Tests/BackendCommandRunnerCheck.swift" \
  -o "$TEMP_ROOT/backend-command-runner-check"
"$TEMP_ROOT/backend-command-runner-check" \
  "$PROJECT_ROOT/Tests/Fixtures/backend-command-runner.sh"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$PROJECT_ROOT/Sources/ConnectionDetailFormatter.swift" \
  "$PROJECT_ROOT/Tests/ConnectionDetailFormatterCheck.swift" \
  -o "$TEMP_ROOT/connection-detail-formatter-check"
"$TEMP_ROOT/connection-detail-formatter-check"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$PROJECT_ROOT/Tests/AppStatePoliciesCheck.swift" \
  -o "$TEMP_ROOT/app-state-policies-check"
"$TEMP_ROOT/app-state-policies-check"

/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/BundledResourceIntegrity.swift" \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$PROJECT_ROOT/Sources/KillSwitchAdminService.swift" \
  "$PROJECT_ROOT/Sources/UpdateService.swift" \
  "$PROJECT_ROOT/Tests/PrivilegedBridgeCheck.swift" \
  -o "$TEMP_ROOT/privileged-bridge-check"
"$TEMP_ROOT/privileged-bridge-check"

# Compile the actual activation callback with fake local/public refresh hooks.
# This verifies lifecycle wiring without starting the app or querying any network.
activation_refresh_method=$(/usr/bin/sed -n '/^    func applicationDidBecomeActive() {/,/^    func applicationDidResignActive() {/p' "$APP_SOURCE" | /usr/bin/sed '$d')
/bin/cat > "$TEMP_ROOT/activation-refresh-check.swift" <<'SWIFT'
import Foundation
@MainActor
final class ActivationRefreshProbe {
    var needsExitRefreshWhenActive = false
    var localRefreshes = 0
    var publicExitRefreshes = 0
    let localRefreshCompletion: AsyncStream<Bool>
    let localRefreshSignal: AsyncStream<Bool>.Continuation
    init() {
        let completion = AsyncStream<Bool>.makeStream()
        localRefreshCompletion = completion.stream
        localRefreshSignal = completion.continuation
    }
    func schedulePathEvaluation() {}
    func scheduleExitRefresh() { publicExitRefreshes += 1 }
    func refresh() async {
        localRefreshes += 1
        localRefreshSignal.yield(true)
        localRefreshSignal.finish()
    }
SWIFT
/usr/bin/printf '%s\n' "$activation_refresh_method" >> "$TEMP_ROOT/activation-refresh-check.swift"
/bin/cat >> "$TEMP_ROOT/activation-refresh-check.swift" <<'SWIFT'
}
@main
struct ActivationRefreshCheck {
    @MainActor
    static func main() async {
        for pendingPathChange in [false, true] {
            let model = ActivationRefreshProbe()
            model.needsExitRefreshWhenActive = pendingPathChange
            model.applicationDidBecomeActive()
            let completed = await waitForLocalRefresh(model.localRefreshCompletion)
            guard completed, model.localRefreshes == 1,
                  model.publicExitRefreshes == (pendingPathChange ? 1 : 0) else {
                FileHandle.standardError.write(Data("Activation must refresh local status while preserving path-gated public exit lookup.\n".utf8))
                exit(1)
            }
        }
        print("ProxyGauge activation refresh cases: 2 passed without GUI or network.")
    }
    private static func waitForLocalRefresh(_ completion: AsyncStream<Bool>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await completed in completion { return completed }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) } catch { return false }
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }
}
SWIFT
/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$TEMP_ROOT/activation-refresh-check.swift" \
  -o "$TEMP_ROOT/activation-refresh-check"
"$TEMP_ROOT/activation-refresh-check"

# Exercise the actual async discovery entry and parser adapter with mock commands.
discovery_refresh_method=$(/usr/bin/sed -n '/^    func discoverConnection(/,/^    func confirmConnection(/p' "$APP_SOURCE" | /usr/bin/sed '$d')
discovery_output_method=$(/usr/bin/sed -n '/^    private func parseDiscovery(/,/^    private func markProbeUnavailable(/p' "$APP_SOURCE" | /usr/bin/sed '$d')
perform_refresh_method=$(/usr/bin/sed -n '/^    private func performRefresh(/,/^    private func startNetworkMonitoring(/p' "$APP_SOURCE" | /usr/bin/sed '$d')
/bin/cat > "$TEMP_ROOT/discovery-refresh-check.swift" <<'SWIFT'
import Foundation
@MainActor
final class DiscoveryRefreshProbe {
    var showConnectionSetup = false
    var isDiscoveringConnection = false
    var refreshGeneration = RefreshGenerationGate()
    var discoveryGeneration = RefreshGenerationGate()
    var guardSelection: GuardSelectionSnapshot?
    var appliedProbes = 0
    var unavailableProbes = 0
    var nextProbeResult: (output: String, status: Int32) = ("valid-mock-probe", 0)
    var discovery = ProxyDiscovery(client: "Clash Verge Rev", core: "verge-mihomo", mode: "TUN")
    var nextResult: (output: String, status: Int32)
    var suspendExecution = false
    var pendingResult: CheckedContinuation<(output: String, status: Int32), Never>?
    let executionStarted: AsyncStream<Bool>
    let executionSignal: AsyncStream<Bool>.Continuation
    init(output: String, status: Int32) {
        nextResult = (output, status)
        let signal = AsyncStream<Bool>.makeStream()
        executionStarted = signal.stream
        executionSignal = signal.continuation
    }
    func refreshForTesting(generation: UInt64, discoveryGeneration: UInt64) async {
        await performRefresh(generation: generation, discoveryGeneration: discoveryGeneration)
    }
    private func applyProbe(_ output: String) { appliedProbes += 1 }
    private func markProbeUnavailable(detail message: String) { unavailableProbes += 1 }
    private static func boundedBackendFailure(_ output: String) -> String { output }
    private func execute(_ action: String) async -> (output: String, status: Int32) {
        if action == "probe" { return nextProbeResult }
        if suspendExecution {
            return await withCheckedContinuation { continuation in
                pendingResult = continuation
                executionSignal.yield(true)
                executionSignal.finish()
            }
        }
        return nextResult
    }
SWIFT
/usr/bin/printf '%s\n%s\n%s\n' "$discovery_refresh_method" "$discovery_output_method" "$perform_refresh_method" >> "$TEMP_ROOT/discovery-refresh-check.swift"
/bin/cat >> "$TEMP_ROOT/discovery-refresh-check.swift" <<'SWIFT'
}
@main
struct DiscoveryRefreshCheck {
    @MainActor
    static func main() async {
        let valid = "found\t0\nclient\tShadowrocket\ncore\tMacPacketTunnel\nendpoint\t127.0.0.1:7890\nmode\tShadowrocket VPN\nsource\t本地运行状态\nactive\tidle\nprivacy\t仅读取本地端口与运行模式，不读取订阅和节点\n"
        let cases: [(String, Int32)] = [
            (valid, 1), (valid, 124), (valid, 130), ("", 0),
            (valid + "mode\t系统代理\n", 0),
            (valid.replacingOccurrences(of: "mode\tShadowrocket VPN", with: "mode\tgarbage"), 0)
        ]
        for (output, status) in cases {
            let model = DiscoveryRefreshProbe(output: output, status: status)
            await model.discoverConnection()
            guard model.discovery.mode == "状态不可用", model.discovery.core.isEmpty,
                  model.discovery.client == "未识别", !model.isDiscoveringConnection else {
                fail("Failed or malformed discovery must replace a previous attributed proxy snapshot.")
            }
        }
        let validModel = DiscoveryRefreshProbe(output: valid, status: 0)
        await validModel.discoverConnection()
        guard validModel.discovery.mode == "Shadowrocket VPN",
              validModel.discovery.core == "MacPacketTunnel" else {
            fail("Fresh discovery must retain the actual observed engine.")
        }
        let delayed = DiscoveryRefreshProbe(output: valid, status: 0)
        delayed.suspendExecution = true
        let work = Task { await delayed.discoverConnection() }
        guard await waitForExecution(delayed.executionStarted) else {
            fail("The suspended discovery mock did not start within two seconds.")
        }
        _ = delayed.discoveryGeneration.request()
        let newer = ProxyDiscovery(client: "Clash Verge Rev", core: "verge-mihomo", mode: "TUN")
        delayed.discovery = newer
        delayed.pendingResult?.resume(returning: delayed.nextResult)
        delayed.pendingResult = nil
        await work.value
        guard delayed.discovery == newer, !delayed.isDiscoveringConnection else {
            fail("An older discovery result must not overwrite a newer proxy generation.")
        }
        for invalidateWholeRefresh in [true, false] {
            let model = DiscoveryRefreshProbe(output: valid, status: 0)
            model.suspendExecution = true
            let refreshGeneration = model.refreshGeneration.request()
            let discoveryGeneration = model.discoveryGeneration.request()
            let refreshWork = Task {
                await model.refreshForTesting(generation: refreshGeneration, discoveryGeneration: discoveryGeneration)
            }
            guard await waitForExecution(model.executionStarted) else {
                fail("The suspended refresh mock did not start within two seconds.")
            }
            if invalidateWholeRefresh { _ = model.refreshGeneration.request() }
            _ = model.discoveryGeneration.request()
            model.discovery = newer
            model.pendingResult?.resume(returning: model.nextResult)
            model.pendingResult = nil
            await refreshWork.value
            guard model.discovery == newer,
                  model.appliedProbes == (invalidateWholeRefresh ? 0 : 1),
                  model.unavailableProbes == 0 else {
                fail("Late refresh results must honor the separate refresh and discovery generations.")
            }
        }
        let probeFailed = DiscoveryRefreshProbe(output: valid, status: 0)
        probeFailed.nextProbeResult = ("mock probe timeout", 124)
        await probeFailed.refreshForTesting(
            generation: probeFailed.refreshGeneration.request(),
            discoveryGeneration: probeFailed.discoveryGeneration.request())
        guard probeFailed.discovery.mode == "Shadowrocket VPN",
              probeFailed.discovery.core == "MacPacketTunnel",
              probeFailed.unavailableProbes == 1, probeFailed.appliedProbes == 0,
              ConnectionStatusPresentation.make(mode: probeFailed.discovery.mode, networkAvailable: true, probeAvailable: false)?.tone == .ok else {
            fail("Fresh discovery evidence must remain factual when the separate health probe fails.")
        }
        let discoveryFailed = DiscoveryRefreshProbe(output: valid, status: 124)
        await discoveryFailed.refreshForTesting(
            generation: discoveryFailed.refreshGeneration.request(),
            discoveryGeneration: discoveryFailed.discoveryGeneration.request())
        guard discoveryFailed.discovery.mode == "状态不可用",
              discoveryFailed.discovery.core.isEmpty,
              discoveryFailed.appliedProbes == 1,
              ConnectionStatusPresentation.make(mode: discoveryFailed.discovery.mode, networkAvailable: true, probeAvailable: true)?.tone == .error else {
            fail("A successful health probe must not turn failed discovery into a confirmed proxy card.")
        }
        print("ProxyGauge async discovery cases: 12 passed without GUI or network.")
    }
    private static func waitForExecution(_ started: AsyncStream<Bool>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await started in started { return started }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) } catch { return false }
                return false
            }
            let started = await group.next() ?? false
            group.cancelAll()
            return started
        }
    }
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
SWIFT
/usr/bin/xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -parse-as-library \
  "$PROJECT_ROOT/Sources/LocalEndpointPolicy.swift" \
  "$PROJECT_ROOT/Sources/AppStatePolicies.swift" \
  "$PROJECT_ROOT/Sources/ExitSummaryService.swift" \
  "$TEMP_ROOT/discovery-refresh-check.swift" \
  -o "$TEMP_ROOT/discovery-refresh-check"
"$TEMP_ROOT/discovery-refresh-check"

echo 'ProxyGauge dashboard semantics tests passed.'
