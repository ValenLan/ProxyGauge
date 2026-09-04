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
/usr/bin/grep -Fq '.background(AppThemePalette.canvas)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq '.tint(AppThemePalette.accent)' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'Click="GuardButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'x:Name="ExitCardTitle" Text="系统实际出口" FontSize="11" FontWeight="Medium"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'FontSize="18" FontWeight="SemiBold" Margin="0,8,0,0"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Text="IP 纯净度" FontSize="14" FontWeight="SemiBold"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="IpPurityButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="PrivacyButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'Style="{StaticResource DashboardCardButtonStyle}" Click="SpeedButton_Click"' "$WINDOWS_MAIN"
/usr/bin/grep -Fq 'https://speed.cloudflare.com/' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'let exit = networkPathSatisfied == false' "$APP_SOURCE"
/usr/bin/grep -Fq ': await exitSummaryService.resolve()' "$APP_SOURCE"
/usr/bin/grep -Fq 'NWPathMonitor()' "$APP_SOURCE"
/usr/bin/grep -Fq 'refreshGeneration.accepts(generation)' "$APP_SOURCE"
/usr/bin/grep -Fq 'NSApplication.didBecomeActiveNotification' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'NSApplication.didResignActiveNotification' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'Text("系统实际出口")' "$DASHBOARD_SOURCE"
/usr/bin/grep -Fq 'URLSessionConfiguration.ephemeral' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'configuration.urlCache = nil' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'withTaskGroup(' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'https://ipwho.is/?fields=success,ip,country,country_code,region,city' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'let session = URLSession(' "$EXIT_SERVICE"
/usr/bin/grep -Fq 'Task.sleep(for: .seconds(5 * 60))' "$APP_SOURCE"
/usr/bin/grep -Fq 'CFNetworkCopySystemProxySettings()' "$APP_SOURCE"
/usr/bin/grep -Fq 'SHA256.hash(data: Data(stableDescription(relevantSettings).utf8))' "$APP_SOURCE"
/usr/bin/grep -Fq 'self.automaticRefreshTask = nil' "$APP_SOURCE"
/usr/bin/grep -Fq 'guard NSApplication.shared.isActive else {' "$APP_SOURCE"
/usr/bin/grep -Fq 'automaticRefreshTask?.cancel()' "$APP_SOURCE"
/usr/bin/grep -Fq '!Self.hasDetectedSystemPath(self.discovery.mode)' "$APP_SOURCE"
/usr/bin/grep -Fq 'Task.sleep(for: .seconds(2))' "$APP_SOURCE"
/usr/bin/grep -Fq 'timeoutSeconds = 15 * 60' "$APP_SOURCE"
/usr/bin/grep -Fq 'await self.detectLocalStateChange()' "$APP_SOURCE"
/usr/bin/grep -Fq 'let result = await execute("fingerprint")' "$APP_SOURCE"
/usr/bin/grep -Fq 'previous != current else { return }' "$APP_SOURCE"
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
/usr/bin/grep -Fq 'source: "自动检测失败"' "$APP_SOURCE"
/usr/bin/grep -Fq 'markProbeUnavailable(' "$APP_SOURCE"
/usr/bin/grep -Fq 'if await checkForUpdates(silent: true)' "$APP_SOURCE"
/usr/bin/grep -Fq '"其他 VPN 已连接"' "$CONNECTION_FORMATTER"
/usr/bin/grep -Fq '"其他 VPN / 代理已连接"' "$CONNECTION_FORMATTER"
/usr/bin/grep -Fq '"其他系统代理已启用"' "$CONNECTION_FORMATTER"
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

echo 'ProxyGauge dashboard semantics tests passed.'
