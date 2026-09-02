#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(/usr/bin/cd "$([ -n "${BASH_SOURCE[0]:-}" ] && /usr/bin/dirname "${BASH_SOURCE[0]}" || /usr/bin/dirname "$0")/.." && /bin/pwd)

for xaml in \
  Windows/App.xaml \
  Windows/MainWindow.xaml \
  Windows/BubbleDialogWindow.xaml \
  Windows/SettingsWindow.xaml \
  Windows/HealthReportWindow.xaml \
  Windows/DetectionPlanWindow.xaml \
  Windows/RulePackWindow.xaml; do
  /usr/bin/xmllint --noout "$PROJECT_ROOT/$xaml"
done

/usr/bin/grep -Fq 'SecondaryEnabled' "$PROJECT_ROOT/Windows/Models/AppConfig.cs"
/usr/bin/grep -Fq 'Mihomo 本地控制接口' "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
/usr/bin/grep -Fq 'Windows 系统代理' "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
/usr/bin/grep -Fq 'CommonMixedPorts = [7890, 7897];' \
  "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
if /usr/bin/grep -Fq 'CommonMixedPorts = [7890, 7897, 1080]' \
  "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"; then
  echo 'The SOCKS convention port 1080 must not be guessed as a mixed HTTP/SOCKS port.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'LocalEndpointPolicy.IsLoopbackHost' "$PROJECT_ROOT/Windows/SettingsWindow.xaml.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.NormalizeLoopbackHost' "$PROJECT_ROOT/Windows/Services/ConfigService.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.FormatEndpoint' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'public static string FormatEndpoint' "$PROJECT_ROOT/Windows/Services/LocalEndpointPolicy.cs"
/usr/bin/grep -Fq 'LocalEndpointPolicy.IsLoopbackHost' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'ShouldUseTunOnlySystemRoute(snapshot)' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'SelectPrimaryExitRoute(snapshot)' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'UseProxy = false' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'secondaryPortAttribution = await TcpListenerOwnership.ProbeAsync(' \
  "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'Mihomo 控制接口' "$PROJECT_ROOT/Windows/Services/MihomoPlanInspectionService.cs"
/usr/bin/grep -Fq '默认入口与额外入口返回不同公网出口' "$PROJECT_ROOT/Windows/Services/HealthCheckService.cs"
/usr/bin/grep -Fq 'https://ippure.com/' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://ipcheck.ing/?hl=zh' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://browserleaks.com/ip' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://browserleaks.com/webrtc' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://www.dnsleaktest.com/' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'https://speed.cloudflare.com/' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'ExitSummaryService.ResolveAsync' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'https://ipapi.co/json/' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'https://api.ipify.org' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'https://ifconfig.me/ip' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'https://ip.sb/ip' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'CreateSystemRouteClient' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'Proxy = HttpClient.DefaultProxy' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'AllowAutoRedirect = false' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'Task.WhenAll(addressTasks)' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'NoCache = true' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
/usr/bin/grep -Fq 'NoStore = true' "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"
if /usr/bin/grep -Eq 'CreateProxyClient|new WebProxy|config\.Mixed(Host|Port)' \
  "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"; then
  echo 'The Windows main exit card must follow the operating-system route instead of a configured mixed port.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'NetworkChange.NetworkAddressChanged +=' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'NetworkChange.NetworkAddressChanged -=' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'NetworkChange.NetworkAvailabilityChanged +=' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'NetworkChange.NetworkAvailabilityChanged -=' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'ScheduleDebouncedRefresh' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_routeChangeMonitor = new RouteChangeMonitor(DispatchNetworkRefresh);' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_ = _routeChangeMonitor.Start();' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_routeChangeMonitor.Dispose();' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'NotifyRouteChange2(' "$PROJECT_ROOT/Windows/Services/RouteChangeMonitor.cs"
/usr/bin/grep -Fq 'CancelMibChangeNotify2(' "$PROJECT_ROOT/Windows/Services/RouteChangeMonitor.cs"
if /usr/bin/grep -Fq 'if (!_initialRefreshCompleted || !IsLoaded)' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"; then
  echo 'A Windows route change during the initial refresh must queue a newer generation.' >&2
  exit 1
fi
/usr/bin/grep -Fq '_refreshGeneration' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq '"其他 VPN / TUN · 系统路径";' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq '"其他 VPN / TUN · 与系统代理并存"' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'DescribeCombinedRoute(' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'var fixedMihomoDualRoute = localMihomoHealthy' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq '"系统代理 + TUN",' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'DescribeMihomoTunnelRoute(mihomoCoreHealthy)' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'DescribeDetectedSystemRoute(' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'BuildConnectionDetail(' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq '系统路径 · {mode}' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'routeTitle == "TUN 路由" &&' \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'routeValue == "代表性路由已确认"' \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq '"Mihomo · TUN-only"' \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
if /usr/bin/grep -Fq 'routeValue == "已接管"' \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"; then
  echo 'Representative route probes must not be rendered as proof that every destination is captured.' >&2
  exit 1
fi
/usr/bin/grep -Fq '_copyFeedbackCancellation' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_viewModel.PropertyChanged += ViewModel_PropertyChanged' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_viewModel.PropertyChanged -= ViewModel_PropertyChanged' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'Task.Delay(1500, cancellation.Token)' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'OtherTunnelDetected' "$PROJECT_ROOT/Windows/Models/ConnectionDiscoveryResult.cs"
/usr/bin/grep -Fq 'SplitTunnelDetected' "$PROJECT_ROOT/Windows/Models/ConnectionDiscoveryResult.cs"
/usr/bin/grep -Fq 'VirtualNetworkDetected' "$PROJECT_ROOT/Windows/Models/ConnectionDiscoveryResult.cs"
/usr/bin/grep -Fq 'RouteLookupUnknown' "$PROJECT_ROOT/Windows/Models/ConnectionDiscoveryResult.cs"
/usr/bin/grep -Fq 'result.RouteWarning' "$PROJECT_ROOT/Windows/SettingsWindow.xaml.cs"
/usr/bin/grep -Fq '没有找到 Mihomo mixed 入口' "$PROJECT_ROOT/Windows/SettingsWindow.xaml.cs"
/usr/bin/grep -Fq 'ApplyExit(ExitSummary.Checking())' "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'x:Name="ExitCardTitle" Text="系统实际出口"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq '会看到该路径的出口 IP 和请求时间，但不会收到代理配置、订阅或凭据' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Interval = TimeSpan.FromMinutes(5)' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'Interval = TimeSpan.FromSeconds(1)' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'DetectProxyConfigurationChange' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'WinHttpGetIEProxyConfigForCurrentUser' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'Environment.GetEnvironmentVariable("HTTPS_PROXY")' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'public bool MayBypassExitLookup' "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'MaximumControllerResponseBytes = 4 * 1024 * 1024' "$PROJECT_ROOT/Windows/Services/MihomoControllerService.cs"
/usr/bin/grep -Fq 'HttpCompletionOption.ResponseHeadersRead' "$PROJECT_ROOT/Windows/Services/MihomoControllerService.cs"
/usr/bin/grep -Fq 'An HTTP-only proxy must not be treated as covering the HTTPS exit lookup.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Deactivated += MainWindow_Deactivated' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '_refreshDebounceTimer.Stop();' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'CanStartAutomaticRefresh(_isClosed, IsLoaded, IsActive)' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'InstallerTimeoutMilliseconds = 30 * 60 * 1000' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
if /usr/bin/grep -Fq '$p.WaitForExit()' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"; then
  echo 'The in-app Windows updater must not wait indefinitely for msiexec.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'Deactivated -= MainWindow_Deactivated' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'The city lookup response must produce an exit summary.' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'public static bool IsSupportedAddress(string? address)' "$PROJECT_ROOT/Windows/Models/ExitSummary.cs"
/usr/bin/grep -Fq 'IPAddress.TryParse(address, out var parsed)' "$PROJECT_ROOT/Windows/Models/ExitSummary.cs"
/usr/bin/grep -Fq 'return "IPv4";' "$PROJECT_ROOT/Windows/Models/ExitSummary.cs"
/usr/bin/grep -Fq 'parsed.AddressFamily == AddressFamily.InterNetworkV6' "$PROJECT_ROOT/Windows/Models/ExitSummary.cs"
/usr/bin/grep -Fq 'x:Name="ExitIpVersionChip" Text="{Binding ExitIpVersion}"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Visibility="{Binding HasExitIpVersion, Converter={StaticResource BooleanToVisibilityConverter}}"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'An invalid local address must never be inferred as IPv4 or IPv6.' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'ExitSummary.TryNormalizePublicAddress(expectedIp, out normalizedExpectedIp)' \
  "$PROJECT_ROOT/Windows/SettingsWindow.xaml.cs"
/usr/bin/grep -Fq 'ExitSummary.TryNormalizePublicAddress(expectedIp, out normalizedExpectedIp)' \
  "$PROJECT_ROOT/Windows/DetectionPlanWindow.xaml.cs"
if /usr/bin/grep -Eq 'api\.ipapi\.is/\?q=|(^|[^[:alnum:]_])(Network(Type)?|ExitNetwork(Type)?)([^[:alnum:]_]|$)|ASN 未知' \
  "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs" \
  "$PROJECT_ROOT/Windows/Models/ExitSummary.cs" \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs" \
  "$PROJECT_ROOT/Windows/MainWindow.xaml"; then
  echo 'The Windows exit card must not restore upstream network type or ASN data.' >&2
  exit 1
fi
if /usr/bin/grep -Eq 'Read(String|NestedString).*"(version|type|asn|org)"' \
  "$PROJECT_ROOT/Windows/Services/ExitSummaryService.cs"; then
  echo 'The Windows exit summary must derive the IP version locally instead of reading upstream metadata.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'UseShellExecute = true' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'BubbleDialogWindow.Show' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'BubbleDialogKind.Browser' "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq 'CornerRadius="22"' "$PROJECT_ROOT/Windows/BubbleDialogWindow.xaml"
/usr/bin/grep -Fq 'Click="IpPurityButton_Click"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Click="PrivacyButton_Click"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Click="SpeedButton_Click"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Source="Assets/ProxyGauge.png"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'RenderOptions.BitmapScalingMode="HighQuality"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'MinWidth="760" MinHeight="550"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'VerticalContentAlignment="Center"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Margin="22,20,22,20" MaxWidth="920" HorizontalAlignment="Stretch"' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq '<ColumnDefinition Width="12" />' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq '<ColumnDefinition Width="248" />' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq '<Grid Width="52" Height="52" VerticalAlignment="Center">' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq '<RowDefinition Height="112" />' "$PROJECT_ROOT/Windows/MainWindow.xaml"
/usr/bin/grep -Fq 'Color="{DynamicResource CanvasColor}"' "$PROJECT_ROOT/Windows/App.xaml"
/usr/bin/grep -Fq '<Color x:Key="CanvasColor">#181A1C</Color>' "$PROJECT_ROOT/Windows/App.xaml"
/usr/bin/grep -Fq '<Color x:Key="SurfaceColor">#202324</Color>' "$PROJECT_ROOT/Windows/App.xaml"
/usr/bin/grep -Fq '<Color x:Key="TextColor">#E7EAE9</Color>' "$PROJECT_ROOT/Windows/App.xaml"
/usr/bin/grep -Fq '<Color x:Key="AccentColor">#36EC8F</Color>' "$PROJECT_ROOT/Windows/App.xaml"
/usr/bin/grep -Fq 'ThemeValueName = "Theme"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq '["CanvasColor"] = "#FF181A1C"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq '["SurfaceColor"] = "#FF202324"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq '["TextColor"] = "#FFE7EAE9"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq '["AccentColor"] = "#FF36EC8F"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq '["CanvasColor"] = "#FFFFFFFF"' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq 'ApplyPalette(application.Resources, GetPalette(CurrentTheme));' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq 'resources[brushKey] = new SolidColorBrush(color);' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq 'public AppThemeKind ToggleTheme()' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq 'AppThemeKind.HighContrast' "$PROJECT_ROOT/Windows/Services/ThemeService.cs"
/usr/bin/grep -Fq 'A saved dark choice must select the dark palette.' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'UpdateService.CompareVersions' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'SHA256.HashDataAsync' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'using System.Net.Http;' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'using System.IO;' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'msiexec.exe' "$PROJECT_ROOT/Windows/Services/UpdateService.cs"
/usr/bin/grep -Fq 'Content="检查更新"' "$PROJECT_ROOT/Windows/SettingsWindow.xaml"
/usr/bin/grep -Fq 'Windows.Tests/ProxyGauge.Windows.Tests.csproj' "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'Remote hostnames must be rejected.' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq '<TargetFramework>net10.0-windows10.0.26100.0</TargetFramework>' \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj"
/usr/bin/grep -Fq '<SupportedOSPlatformVersion>10.0.22000.0</SupportedOSPlatformVersion>' \
  "$PROJECT_ROOT/Windows/ProxyGauge.Windows.csproj"
/usr/bin/grep -Fq 'dotnet-version: 10.0.x' "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'node --check Scripts/install-release-windows.mjs' "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'npm test' "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)' \
  "$PROJECT_ROOT/Windows/App.xaml.cs"
/usr/bin/grep -Fq 'ProxyGauge 仅支持 Windows 11，不支持 Windows 10。' \
  "$PROJECT_ROOT/Windows/App.xaml.cs"
/usr/bin/grep -Fq 'public bool HasValidConfig => TryLoad(out _);' \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs"
/usr/bin/grep -Fq 'File.Replace(temporaryPath, ConfigPath' \
  "$PROJECT_ROOT/Windows/Services/ConfigService.cs"
/usr/bin/grep -Fq 'GetBestInterfaceEx(' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'BestRouteProbeIpv4' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'BestRouteProbeIpv6' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'IPAddress.Parse("208.67.222.222")' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'IPAddress.Parse("2620:119:35::35")' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'AggregateBestRouteLookups(' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'BestRouteLookup.Inconsistent()' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq '"代表性路由已确认"' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'registryVirtual: carriesBestRoute && IsRegistryVirtualAdapter(adapter.Id)' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'TcpListenerOwnership.ProbeAsync(' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'GetProxyCoreProcessIds()' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'TcpListenerOwnership.ProbeAsync(' \
  "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
/usr/bin/grep -Fq 'ShouldAcceptCandidate(' \
  "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"
if /usr/bin/grep -Fq '_probeService.CountProxyCores() > 0 ?' \
  "$PROJECT_ROOT/Windows/Services/ConnectionDiscoveryService.cs"; then
  echo 'A reachable port must not inherit Mihomo attribution merely because a core process exists.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'GetExtendedTcpTable(' \
  "$PROJECT_ROOT/Windows/Services/TcpListenerOwnership.cs"
/usr/bin/grep -Fq 'OwnerPidListener = 3' \
  "$PROJECT_ROOT/Windows/Services/TcpListenerOwnership.cs"
/usr/bin/grep -Fq 'OwnerPidConnections = 4' \
  "$PROJECT_ROOT/Windows/Services/TcpListenerOwnership.cs"
/usr/bin/grep -Fq 'Marshal.OffsetOf<TcpTableOwnerPidHeader>' \
  "$PROJECT_ROOT/Windows/Services/TcpListenerOwnership.cs"
/usr/bin/grep -Fq 'Marshal.OffsetOf<Tcp6TableOwnerPidHeader>' \
  "$PROJECT_ROOT/Windows/Services/TcpListenerOwnership.cs"
/usr/bin/grep -Fq 'new RoutedAdapterEvidence(TunnelKind.Mihomo, Ipv4Index: 17, Ipv6Index: 23)' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Either IPv4 or IPv6 bypassing Mihomo must downgrade the dual-stack path' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'TunnelKind.VirtualNetwork' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'A failed best-route query must fail closed' "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Only ERROR_NOT_SUPPORTED may prove an address family unavailable' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Within-family interface divergence, including one diverted target, must be reported as split routing.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'One failed native lookup must remain unknown instead of being mistaken for unavailable or split routing.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'One nearby Mihomo core must not make an unrelated reachable port healthy' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'The health report must follow a confirmed TUN-only system route instead of forcing a closed mixed endpoint.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Configured and common ports require Mihomo PID ownership' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'GetExtendedTcpTable must attribute a real loopback listener to the current Windows test PID.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'The same real loopback listener must reject a non-owning PID.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'GetExtendedTcpTable must attribute a real IPv6 loopback listener to the current Windows test PID.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'The connected ownership probe must preserve IPv6 listener attribution.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'An IPv4 connection accepted by an IPv6 dual-mode listener must resolve through the exact connected tuple.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Found and missing mixed endpoints must both preserve the split-route leak warning.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Found and missing mixed endpoints must both preserve virtual-network attribution' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'routeChangeMonitor.Start() && routeChangeMonitor.IsStarted' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'TryGetBestRouteInterfaceIndex(' "$PROJECT_ROOT/Windows.Tests/Program.cs"
if /usr/bin/grep -Eq 'route\.exe|198\.18\.0\.0|CombineTunnelEvidence' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs" \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"; then
  echo 'Windows TUN attribution must use actual IPv4/IPv6 best-route interfaces, not the fake-IP route heuristic.' >&2
  exit 1
fi
/usr/bin/grep -Fq 'A pre-cancelled tunnel probe must not query IP Helper.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Exceptions must never cross the unmanaged callback boundary.' \
  "$PROJECT_ROOT/Windows/Services/RouteChangeMonitor.cs"
/usr/bin/grep -Fq 'return registryVirtual ? TunnelKind.VirtualNetwork : TunnelKind.None;' \
  "$PROJECT_ROOT/Windows/Services/ProxyProbeService.cs"
/usr/bin/grep -Fq 'A corrupt config must require setup.' \
  "$PROJECT_ROOT/Windows.Tests/Program.cs"
/usr/bin/grep -Fq 'Closing the UI must never disable protection.' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml.cs"
/usr/bin/grep -Fq '退出 ProxyGauge 后仍持续拦截直连' \
  "$PROJECT_ROOT/Windows/ViewModels/MainViewModel.cs"
/usr/bin/grep -Fq 'ProxyGauge.Guard.v1' \
  "$PROJECT_ROOT/Windows/Services/GuardClient.cs"
/usr/bin/grep -Fq 'GenericRead | FileWriteData' \
  "$PROJECT_ROOT/Windows/Services/GuardClient.cs"
/usr/bin/grep -Fq 'GetNamedPipeServerProcessId' \
  "$PROJECT_ROOT/Windows/Services/GuardClient.cs"
/usr/bin/grep -Fq 'QueryServiceStatusEx' \
  "$PROJECT_ROOT/Windows/Services/GuardClient.cs"
/usr/bin/grep -Fq 'FWPM_FILTER_FLAG_PERSISTENT' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'provider.serviceName = const_cast<wchar_t*>(ServiceName);' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'FWPM_CONDITION_ALE_USER_ID' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'FWPM_LAYER_ALE_AUTH_CONNECT_V6' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq '(A;;GR;;;AU)(A;;0x00000002;;;AU)' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'FILE_FLAG_FIRST_PIPE_INSTANCE' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq -- '--emergency-off' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq -- '--uninstall-cleanup' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'RegDeleteTreeW(HKEY_LOCAL_MACHINE, RegistryPath)' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'DisableGuard(false)' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'DisableGuard(true)' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'ControlService(service, SERVICE_CONTROL_STOP' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp"
/usr/bin/grep -Fq 'Start="auto"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'WINDOWS_CURRENT_BUILD &gt;= 22000' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'Name="CurrentBuild"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'After="StopServices"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'Id="ProxyGaugeStartMenuShortcut"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'Id="ProxyGaugeDesktopShortcut"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'Scope="perMachine"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq '<StandardDirectory Id="DesktopFolder" />' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
if [ "$(/usr/bin/grep -Fc 'Advertise="yes"' "$PROJECT_ROOT/Windows.Installer/Package.wxs")" -ne 2 ]; then
  echo 'Each Windows shortcut must use the executable component as its advertised target.' >&2
  exit 1
fi
if [ "$(/usr/bin/grep -Fc 'Icon="ProxyGaugeIcon.ico"' "$PROJECT_ROOT/Windows.Installer/Package.wxs")" -ne 2 ] \
  || [ "$(/usr/bin/grep -Fc 'IconIndex="0"' "$PROJECT_ROOT/Windows.Installer/Package.wxs")" -ne 2 ]; then
  echo 'Each Windows shortcut must explicitly reference the packaged ProxyGauge icon.' >&2
  exit 1
fi
/usr/bin/grep -Fq '<StandardDirectory Id="ProgramMenuFolder" />' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq '<Icon Id="ProxyGaugeIcon.ico"' \
  "$PROJECT_ROOT/Windows.Installer/Package.wxs"
/usr/bin/grep -Fq 'ProxyGauge.Guard.exe' \
  "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'ProxyGauge.Installer.wixproj' \
  "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'DOTNET-THIRD-PARTY-NOTICES.txt' \
  "$PROJECT_ROOT/.github/workflows/build.yml"
/usr/bin/grep -Fq 'WiX-6.0.2-LICENSE.txt' \
  "$PROJECT_ROOT/.github/workflows/build.yml"

if /usr/bin/grep -Eq 'uses:[[:space:]]+[^[:space:]]+@v[0-9]+' \
  "$PROJECT_ROOT/.github/workflows/build.yml"; then
  echo 'GitHub Actions must be pinned to immutable commit SHAs.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'GetRawText\(' "$PROJECT_ROOT/Windows/Services/MihomoPlanInspectionService.cs"; then
  echo 'Windows plan inspection must not render raw Mihomo controller data.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'ProxyGauge-.*win-(x64|arm64)\.zip' "$PROJECT_ROOT/.github/workflows/build.yml"; then
  echo 'Windows release must be an MSI so Guard remains independently installed.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'MaxWidth="1000"|MaxHeight="550"' "$PROJECT_ROOT/Windows/MainWindow.xaml"; then
  echo 'The Windows dashboard must remain maximizable.' >&2
  exit 1
fi

if /usr/bin/grep -Fq '(A;;GRGW;;;AU)' "$PROJECT_ROOT/Windows.Guard/Guard.cpp"; then
  echo 'Authenticated users must not receive FILE_GENERIC_WRITE on the Guard pipe.' >&2
  exit 1
fi

if /usr/bin/grep -Eq 'PAUSED|PauseGuard|暂停[[:space:]]*10[[:space:]]*分钟' \
  "$PROJECT_ROOT/Windows.Guard/Guard.cpp" \
  "$PROJECT_ROOT/Windows/Services/GuardProtocol.cs" \
  "$PROJECT_ROOT/Windows/MainWindow.xaml"; then
  echo 'Windows Guard must expose a persistent on/off switch, not a timed pause.' >&2
  exit 1
fi

if /usr/bin/grep -E '#[0-9A-Fa-f]{6,8}' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml" \
  "$PROJECT_ROOT/Windows/BubbleDialogWindow.xaml" \
  "$PROJECT_ROOT/Windows/SettingsWindow.xaml" \
  "$PROJECT_ROOT/Windows/HealthReportWindow.xaml" \
  "$PROJECT_ROOT/Windows/DetectionPlanWindow.xaml" \
  "$PROJECT_ROOT/Windows/RulePackWindow.xaml" >/dev/null; then
  echo 'Window colors must come from shared light/dark theme tokens.' >&2
  exit 1
fi

if [ "$(/usr/bin/grep -Fc 'Stretch="Fill" Data="{StaticResource IconChevron}"' \
  "$PROJECT_ROOT/Windows/MainWindow.xaml")" -ne 4 ]; then
  echo 'Every dashboard chevron must scale its shared geometry into the declared viewport.' >&2
  exit 1
fi

if /usr/bin/grep -R -E '\{StaticResource [A-Za-z][A-Za-z0-9]*Brush\}' \
  "$PROJECT_ROOT/Windows" --include='*.xaml' >/dev/null; then
  echo 'Theme brushes must use DynamicResource so open windows update at runtime.' >&2
  exit 1
fi

if /usr/bin/grep -R -n 'MessageBox' \
  "$PROJECT_ROOT/Windows" --include='*.cs' --include='*.xaml' >/dev/null; then
  echo 'Windows in-app prompts must use the shared bubble dialog.' >&2
  exit 1
fi

echo 'ProxyGauge Windows parity static checks passed.'
