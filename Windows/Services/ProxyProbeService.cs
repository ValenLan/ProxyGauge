using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

internal sealed record SystemProxyConfiguration(
    bool ExplicitEnabled,
    string? ExplicitHost,
    int? ExplicitPort,
    bool ExplicitCoversHttps,
    bool PacEnabled,
    string? PacUrl,
    bool AutoDetectEnabled,
    string? ProxyBypass,
    bool EnvironmentProxyEnabled,
    string? EnvironmentFingerprint)
{
    public bool Enabled => ExplicitEnabled || PacEnabled || AutoDetectEnabled || EnvironmentProxyEnabled;
    public bool UsesDynamicResolution => PacEnabled || AutoDetectEnabled;
    public bool HasValidExplicitEndpoint =>
        ExplicitEnabled && !string.IsNullOrWhiteSpace(ExplicitHost) && ExplicitPort is > 0 and <= 65535;
    public string ExplicitEndpoint => HasValidExplicitEndpoint
        ? ExplicitHost!.Trim('[', ']').Contains(':')
            ? $"[{ExplicitHost.Trim('[', ']')}]:{ExplicitPort}"
            : $"{ExplicitHost}:{ExplicitPort}"
        : "未配置有效端点";

    public bool Matches(string host, int port)
    {
        if (!ExplicitCoversHttps || !HasValidExplicitEndpoint || port != ExplicitPort)
        {
            return false;
        }

        var configured = LocalEndpointPolicy.NormalizeLoopbackHost(host);
        var system = LocalEndpointPolicy.IsLoopbackHost(ExplicitHost)
            ? LocalEndpointPolicy.NormalizeLoopbackHost(ExplicitHost)
            : ExplicitHost!.Trim();
        return string.Equals(configured, system, StringComparison.OrdinalIgnoreCase);
    }

    public bool MayBypassExitLookup => ExitLookupHosts.Any(IsBypassed);

    private static readonly string[] ExitLookupHosts =
        ["ipapi.co", "ipwho.is", "api.ipify.org", "ifconfig.me", "ip.sb"];

    private bool IsBypassed(string host)
    {
        if (string.IsNullOrWhiteSpace(ProxyBypass))
        {
            return false;
        }
        return ProxyBypass.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(pattern => MatchesBypassPattern(pattern, host));
    }

    private static bool MatchesBypassPattern(string pattern, string host)
    {
        pattern = pattern.Trim();
        if (pattern.Length == 0 || pattern.Equals("<local>", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (pattern[0] == '.' &&
            string.Equals(pattern[1..], host, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var patternIndex = 0;
        var hostIndex = 0;
        var starIndex = -1;
        var retryHostIndex = 0;
        while (hostIndex < host.Length)
        {
            if (patternIndex < pattern.Length && pattern[patternIndex] != '*' &&
                char.ToUpperInvariant(pattern[patternIndex]) == char.ToUpperInvariant(host[hostIndex]))
            {
                patternIndex++;
                hostIndex++;
                continue;
            }

            if (patternIndex < pattern.Length && pattern[patternIndex] == '*')
            {
                starIndex = patternIndex++;
                retryHostIndex = hostIndex;
                continue;
            }

            if (starIndex < 0)
            {
                return false;
            }

            patternIndex = starIndex + 1;
            hostIndex = ++retryHostIndex;
        }

        while (patternIndex < pattern.Length && pattern[patternIndex] == '*')
        {
            patternIndex++;
        }
        return patternIndex == pattern.Length;
    }
}

internal enum TunnelKind
{
    None,
    Mihomo,
    Other,
    VirtualNetwork,
    Split,
    Unknown
}

internal readonly record struct BestRouteInterfaceIndexes(
    uint? Ipv4,
    uint? Ipv6,
    bool Ipv4Unknown = false,
    bool Ipv6Unknown = false,
    bool Ipv4Split = false,
    bool Ipv6Split = false);

internal readonly record struct BestRouteLookup(
    uint? InterfaceIndex,
    bool Unknown,
    bool Split = false)
{
    public static BestRouteLookup Resolved(uint interfaceIndex) => new(interfaceIndex, false, false);
    public static BestRouteLookup Unavailable() => new(null, false, false);
    public static BestRouteLookup Failed() => new(null, true, false);
    public static BestRouteLookup Inconsistent() => new(null, false, true);
}

internal readonly record struct RoutedAdapterEvidence(
    TunnelKind Kind,
    int? Ipv4Index,
    int? Ipv6Index,
    string? ClientName = null);

internal sealed record RouteDetection(
    TunnelKind Coverage,
    bool MihomoDetected,
    bool OtherTunnelDetected,
    bool LookupUnknown = false,
    string? ClientName = null);

public sealed class ProxyProbeService
{
    [StructLayout(LayoutKind.Sequential)]
    private struct CurrentUserIeProxyConfig
    {
        [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
        public IntPtr AutoConfigUrl;
        public IntPtr Proxy;
        public IntPtr ProxyBypass;
    }

    [DllImport("winhttp.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpGetIEProxyConfigForCurrentUser(
        out CurrentUserIeProxyConfig proxyConfig);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr memory);

    private const uint NoError = 0;
    private const uint ErrorNotSupported = 50;
    private const uint NcfVirtual = 0x1;
    private const string NetworkAdapterClassPath =
        @"SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}";

    // GetBestInterfaceEx only asks Windows which route it would use; these addresses are never contacted.
    // Independent provider prefixes make a single host-route diversion visible as split routing.
    private static readonly IPAddress[] BestRouteProbeIpv4 =
    [
        IPAddress.Parse("1.1.1.1"),
        IPAddress.Parse("8.8.8.8"),
        IPAddress.Parse("9.9.9.9"),
        IPAddress.Parse("208.67.222.222")
    ];

    private static readonly IPAddress[] BestRouteProbeIpv6 =
    [
        IPAddress.Parse("2606:4700:4700::1111"),
        IPAddress.Parse("2001:4860:4860::8888"),
        IPAddress.Parse("2620:fe::fe"),
        IPAddress.Parse("2620:119:35::35")
    ];

    private static readonly string[] CoreProcessNames =
    [
        "verge-mihomo",
        "mihomo",
        "clash-meta",
        "clash"
    ];

    private static readonly string[] MihomoTunKeywords =
    [
        "mihomo",
        "clash",
        "meta tun"
    ];

    private static readonly string[] OtherTunnelKeywords =
    [
        "wintun",
        "wireguard",
        "sing-box",
        "tailscale",
        "openvpn",
        "vpn",
        "tun adapter",
        "tap adapter"
    ];

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint GetBestInterfaceEx(
        IntPtr destinationAddress,
        out uint bestInterfaceIndex);

    public async Task<ProxySnapshot> ProbeAsync(AppConfig config, CancellationToken cancellationToken = default)
    {
        var coreProcessIds = GetProxyCoreProcessIds();
        var coreCount = coreProcessIds.Count;
        var portAttributionTask = TcpListenerOwnership.ProbeAsync(
            config.MixedHost,
            config.MixedPort,
            coreProcessIds,
            config.TimeoutSeconds,
            cancellationToken);
        var tunTask = DetectRouteAsync(cancellationToken);
        var systemProxy = ReadSystemProxyConfiguration();
        await Task.WhenAll(portAttributionTask, tunTask);
        var detection = await tunTask;
        return CreateSnapshot(
            config,
            coreCount,
            await portAttributionTask,
            systemProxy,
            detection,
            detection.ClientName ?? DetectRunningProxyClientName());
    }

    internal static ProxySnapshot CreateSnapshot(AppConfig config, int coreCount,
        TcpListenerAttribution portAttribution, SystemProxyConfiguration systemProxy, RouteDetection detection,
        string? detectedClientName = null)
    {
        var snapshot = BuildSnapshot(config, coreCount, portAttribution, systemProxy, detection);
        return snapshot with
        {
            SplitTunnelDetected = detection.Coverage == TunnelKind.Split,
            RouteLookupUnknown = detection.LookupUnknown || detection.Coverage == TunnelKind.Unknown,
            VirtualNetworkDetected = detection.Coverage != TunnelKind.None,
            DetectedClientName = detectedClientName ?? detection.ClientName
                ?? (coreCount > 0 ? "Clash / Mihomo" : null),
            ConnectionLabel = coreCount > 1 ? null : detection.OtherTunnelDetected ? "VPN 已检测"
                : detection.MihomoDetected && (detection.Coverage == TunnelKind.Split || detection.LookupUnknown)
                    ? "TUN 已检测" : null,
            ConnectionSummary = detection.OtherTunnelDetected
                ? detection.LookupUnknown ? "VPN / TUN · 部分路由未确认"
                    : detection.Coverage == TunnelKind.Split ? "VPN / TUN · 路由分流"
                    : "VPN / TUN · 系统路径"
                : null
        };
    }

    private static ProxySnapshot BuildSnapshot(AppConfig config, int coreCount,
        TcpListenerAttribution portAttribution, SystemProxyConfiguration systemProxy, RouteDetection detection)
    {
        var systemProxyEnabled = systemProxy.Enabled;
        var explicitMismatch = systemProxy.ExplicitEnabled && !systemProxy.UsesDynamicResolution && !systemProxy.Matches(
            config.MixedHost,
            config.MixedPort);
        var httpsCoverageMissing = systemProxy.ExplicitEnabled && !systemProxy.UsesDynamicResolution &&
            !systemProxy.ExplicitCoversHttps;
        var pacManaged = systemProxy.PacEnabled;
        var autoManaged = systemProxy.AutoDetectEnabled;
        var environmentManaged = systemProxy.EnvironmentProxyEnabled;
        var bypassManaged = systemProxy.MayBypassExitLookup;

        var tunnelKind = detection.Coverage;
        var tunDetected = detection.MihomoDetected;
        var otherTunnelDetected = detection.OtherTunnelDetected;
        var virtualNetworkDetected = tunnelKind == TunnelKind.VirtualNetwork;
        var splitTunnelDetected = tunnelKind == TunnelKind.Split;
        var routeLookupUnknown = detection.LookupUnknown || tunnelKind == TunnelKind.Unknown;
        var anyTunnelDetected = tunnelKind != TunnelKind.None;
        var routeActive = systemProxyEnabled || anyTunnelDetected;

        var core = coreCount switch
        {
            0 when otherTunnelDetected => new MetricSnapshot("代理核心", "VPN / TUN 已检测",
                "已确认活动 VPN 路由；该客户端不要求使用 Mihomo 或保存的 mixed 端口", "核", HealthLevel.Warning),
            0 => new MetricSnapshot("代理核心", "未运行", "未发现 Clash / Mihomo 进程或活动 VPN 路由", "核", HealthLevel.Error),
            1 => new MetricSnapshot("代理核心", "运行中", "检测到一个核心进程", "核", HealthLevel.Ok),
            _ => new MetricSnapshot("代理核心", $"{coreCount} 个进程", "可能存在双核心冲突", "核", HealthLevel.Warning)
        };

        var mihomoCoreHealthy = coreCount == 1;
        var configuredEndpointOwnedByMihomo =
            portAttribution == TcpListenerAttribution.MihomoOwned;
        var localMihomoHealthy = mihomoCoreHealthy && configuredEndpointOwnedByMihomo;
        var mihomoTunHealthy = mihomoCoreHealthy && tunnelKind == TunnelKind.Mihomo && !routeLookupUnknown;
        var configuredPortConflict = portAttribution == TcpListenerAttribution.OtherOrUnknown;
        var port = DescribeLocalPort(
            config.MixedHost,
            config.MixedPort,
            portAttribution,
            mihomoTunHealthy,
            alternateSystemPath: otherTunnelDetected || (tunDetected && !mihomoTunHealthy) ||
                pacManaged || autoManaged || environmentManaged);
        MetricSnapshot route;
        if (anyTunnelDetected && systemProxyEnabled)
        {
            route = DescribeCombinedRoute(
                systemProxy,
                otherTunnelDetected,
                localMihomoHealthy,
                config.MixedHost,
                config.MixedPort,
                virtualNetworkDetected,
                splitTunnelDetected,
                routeLookupUnknown);
        }
        else if (routeLookupUnknown)
        {
            route = DescribeUnknownRoute();
        }
        else if (splitTunnelDetected)
        {
            route = DescribeSplitTunnelRoute();
        }
        else if (tunDetected)
        {
            route = DescribeMihomoTunnelRoute(mihomoCoreHealthy);
        }
        else if (otherTunnelDetected)
        {
            route = new MetricSnapshot(
                "其他 VPN / TUN",
                "已检测",
                "系统路径可能由其他隧道接管，不能归因于当前 Mihomo 入口",
                "入",
                HealthLevel.Warning);
        }
        else if (virtualNetworkDetected)
        {
            route = new MetricSnapshot(
                "虚拟网络路径",
                "已检测",
                "系统最佳路由由虚拟 Ethernet 承载；仅凭虚拟网卡不能判定为 VPN/TUN",
                "入",
                HealthLevel.Warning);
        }
        else if (systemProxyEnabled)
        {
            if (environmentManaged)
            {
                route = new MetricSnapshot(
                    "环境代理",
                    "按进程环境决定",
                    "HTTPS_PROXY / ALL_PROXY / NO_PROXY 会优先影响本进程实际出口",
                    "入",
                    HealthLevel.Warning);
            }
            else if (httpsCoverageMissing)
            {
                route = new MetricSnapshot(
                    "系统代理",
                    "HTTPS 未接管",
                    "仅配置 HTTP 代理，不能据此确认 HTTPS 流量已进入当前代理",
                    "入",
                    HealthLevel.Warning);
            }
            else if (explicitMismatch)
            {
                route = new MetricSnapshot(
                    "系统代理",
                    "入口不匹配",
                    $"Windows 指向 {systemProxy.ExplicitEndpoint}，检测设置为 {LocalEndpointPolicy.FormatEndpoint(config.MixedHost, config.MixedPort)}",
                    "入",
                    HealthLevel.Warning);
            }
            else if (pacManaged)
            {
                route = new MetricSnapshot(
                    "PAC 代理",
                    "按脚本决定",
                    "Windows PAC 会按目标地址动态选择代理或直连，不能等同于固定检测端口",
                    "入",
                    HealthLevel.Warning);
            }
            else if (autoManaged)
            {
                route = new MetricSnapshot(
                    "自动代理",
                    "WPAD 自动发现",
                    "Windows 会自动发现代理，不能等同于固定检测端口",
                    "入",
                    HealthLevel.Warning);
            }
            else if (bypassManaged)
            {
                route = new MetricSnapshot(
                    "系统代理",
                    "出口域名被绕过",
                    "Windows 绕过列表可能让出口查询直连，不能据此确认当前代理入口",
                    "入",
                    HealthLevel.Warning);
            }
            else if (systemProxy.ExplicitEnabled && !configuredEndpointOwnedByMihomo)
            {
                var endpointIsListening = portAttribution == TcpListenerAttribution.OtherOrUnknown;
                route = new MetricSnapshot(
                    "系统代理",
                    endpointIsListening ? "本地代理（未归属 Mihomo）" : "端点不可用",
                    endpointIsListening
                        ? $"Windows 指向 {systemProxy.ExplicitEndpoint}，但该监听 PID 未归属于已检测的 Mihomo 进程"
                        : $"Windows 指向 {systemProxy.ExplicitEndpoint}，但该端点未监听",
                    "入",
                    HealthLevel.Warning);
            }
            else
            {
                route = new MetricSnapshot("系统代理", "已启用", "Windows 代理端点与检测设置一致", "入", HealthLevel.Ok);
            }
        }
        else
        {
            route = new MetricSnapshot("流量入口", "未启用", "系统代理与 TUN 均未检测到", "入", HealthLevel.Idle);
        }

        if (localMihomoHealthy &&
            route.Title == "双重入口" &&
            route.Value == "同时开启")
        {
            return new ProxySnapshot(
                "入口同时开启",
                "系统代理与隧道均已启用",
                HealthLevel.Warning,
                core,
                port,
                route,
                systemProxyEnabled,
                tunDetected,
                otherTunnelDetected);
        }

        if (HasHealthyMihomoPath(coreCount, portAttribution, tunnelKind) && routeActive)
        {
            if (environmentManaged || httpsCoverageMissing || explicitMismatch || pacManaged ||
                autoManaged || bypassManaged || otherTunnelDetected ||
                virtualNetworkDetected || splitTunnelDetected || routeLookupUnknown ||
                configuredPortConflict || route.Level == HealthLevel.Warning)
            {
                var warningHeadline = environmentManaged
                    ? "环境代理路径需确认"
                    : httpsCoverageMissing
                        ? "HTTPS 路径未接管"
                        : explicitMismatch
                            ? "入口配置不一致"
                            : pacManaged
                                ? "PAC 路径需确认"
                                : autoManaged
                                    ? "自动代理路径需确认"
                                    : bypassManaged
                                        ? "出口绕过规则需确认"
                                        : otherTunnelDetected
                                            ? "检测到其他 VPN/TUN"
                                            : virtualNetworkDetected
                                                ? "检测到虚拟网络路径"
                                                : splitTunnelDetected
                                                    ? "系统路由存在分流"
                                                    : routeLookupUnknown
                                                        ? "系统路由状态无法确认"
                                                        : configuredPortConflict
                                                            ? "本地端口未归属 Mihomo"
                                                            : "系统路径需确认";
                var portConflictIsPrimary = configuredPortConflict &&
                    !environmentManaged && !httpsCoverageMissing && !explicitMismatch &&
                    !pacManaged && !autoManaged && !bypassManaged && !otherTunnelDetected &&
                    !virtualNetworkDetected && !splitTunnelDetected && !routeLookupUnknown;
                return new ProxySnapshot(
                    warningHeadline,
                    portConflictIsPrimary ? port.Detail : route.Detail,
                    HealthLevel.Warning,
                    core,
                    port,
                    route,
                    systemProxyEnabled,
                    tunDetected,
                    otherTunnelDetected);
            }

            return new ProxySnapshot(
                tunDetected ? "Mihomo 代表性路由已确认" : "代理路径已确认",
                tunDetected
                    ? "所检查的多个独立 IPv4 / IPv6 公网前缀均由 Mihomo 承载"
                    : "本地入口、代理核心与所检查的系统路径工作正常",
                HealthLevel.Ok,
                core,
                port,
                route,
                systemProxyEnabled,
                tunDetected,
                otherTunnelDetected);
        }

        if (coreCount > 1)
        {
            return new ProxySnapshot(
                "检测到状态冲突",
                "多个代理核心可能同时接管流量",
                HealthLevel.Warning,
                core,
                port,
                route,
                systemProxyEnabled,
                tunDetected,
                otherTunnelDetected);
        }

        var detectedSystemRoute = DescribeDetectedSystemRoute(
            routeActive,
            systemProxyEnabled,
            otherTunnelDetected,
            route.Detail,
            virtualNetworkDetected,
            splitTunnelDetected,
            routeLookupUnknown);
        if (detectedSystemRoute is not null)
        {
            return new ProxySnapshot(
                detectedSystemRoute.Value.Headline,
                detectedSystemRoute.Value.Detail,
                HealthLevel.Warning,
                core,
                port,
                route,
                systemProxyEnabled,
                tunDetected,
                otherTunnelDetected);
        }

        return new ProxySnapshot(
            "代理未完整生效",
            "请检查代理核心、本地入口与当前系统代理或 TUN 状态",
            HealthLevel.Error,
            core,
            port,
            route,
            systemProxyEnabled,
            tunDetected,
            otherTunnelDetected);
    }

    internal static MetricSnapshot DescribeCombinedRoute(
        SystemProxyConfiguration systemProxy,
        bool otherTunnelDetected,
        bool localMihomoHealthy,
        string mixedHost,
        int mixedPort,
        bool virtualNetworkDetected = false,
        bool splitTunnelDetected = false,
        bool routeLookupUnknown = false)
    {
        var explicitMismatch = systemProxy.ExplicitEnabled &&
            !systemProxy.UsesDynamicResolution &&
            !systemProxy.Matches(mixedHost, mixedPort);
        var httpsCoverageMissing = systemProxy.ExplicitEnabled &&
            !systemProxy.UsesDynamicResolution &&
            !systemProxy.ExplicitCoversHttps;
        var detail = systemProxy.EnvironmentProxyEnabled
            ? "进程环境代理与隧道均存在；HTTPS 出口由 .NET 默认代理规则决定"
            : httpsCoverageMissing
                ? "只配置了 HTTP 代理，HTTPS 出口不一定被接管；隧道也已启用"
                : explicitMismatch
                    ? $"系统代理指向 {systemProxy.ExplicitEndpoint}，与检测端口 {LocalEndpointPolicy.FormatEndpoint(mixedHost, mixedPort)} 不一致；隧道也已启用"
                    : systemProxy.PacEnabled
                        ? "PAC 与隧道均已启用；PAC 会按目标地址动态决定路径"
                        : systemProxy.AutoDetectEnabled
                            ? "WPAD 自动代理与隧道均已启用；实际出口需按系统路径确认"
                            : systemProxy.MayBypassExitLookup
                                ? "系统代理绕过列表可能让出口查询直连；隧道也已启用"
                                : routeLookupUnknown
                                    ? "系统代理存在，但 IP Helper 未能确认全部代表性公网前缀的路由"
                                    : splitTunnelDetected
                                    ? "系统代理存在，但代表性公网前缀走不同接口或 IPv4 / IPv6 路径不一致"
                                    : virtualNetworkDetected
                                        ? "系统代理与虚拟 Ethernet 系统路径同时存在；虚拟网卡不等同于 VPN/TUN"
                                    : otherTunnelDetected
                                            ? "系统代理与其他 VPN/TUN 均已启用；不能把隧道归因于 Mihomo"
                                            : !localMihomoHealthy
                                                ? "Mihomo 代表性 TUN 路由存在，但系统代理端点未确认由唯一活动 Mihomo 核心监听"
                                                : "系统代理与 Mihomo TUN 均已启用";

        if (routeLookupUnknown)
        {
            return new MetricSnapshot(
                "系统代理 + 路由状态",
                "无法确认",
                detail,
                "入",
                HealthLevel.Warning);
        }

        if (splitTunnelDetected)
        {
            return new MetricSnapshot(
                "系统代理 + 路由分流",
                "路径不一致",
                detail,
                "入",
                HealthLevel.Warning);
        }

        if (virtualNetworkDetected)
        {
            return new MetricSnapshot(
                "系统代理 + 虚拟网络",
                "同时检测",
                detail,
                "入",
                HealthLevel.Warning);
        }

        if (otherTunnelDetected)
        {
            return new MetricSnapshot(
                "系统代理 + 其他 VPN / TUN",
                "同时检测",
                detail,
                "入",
                HealthLevel.Warning);
        }

        var fixedMihomoDualRoute = localMihomoHealthy &&
            systemProxy.ExplicitEnabled &&
            !systemProxy.EnvironmentProxyEnabled &&
            !systemProxy.UsesDynamicResolution &&
            systemProxy.ExplicitCoversHttps &&
            systemProxy.Matches(mixedHost, mixedPort) &&
            !systemProxy.MayBypassExitLookup;
        return fixedMihomoDualRoute
            ? new MetricSnapshot(
                "双重入口",
                "同时开启",
                detail,
                "入",
                HealthLevel.Warning)
            : new MetricSnapshot(
                "系统代理 + TUN",
                "路径需确认",
                detail,
                "入",
                HealthLevel.Warning);
    }

    internal static MetricSnapshot DescribeMihomoTunnelRoute(bool mihomoCoreHealthy) =>
        mihomoCoreHealthy
            ? new MetricSnapshot(
                "TUN 路由",
                "代表性路由已确认",
                "多个独立公网前缀的 IPv4 / IPv6 路由均由活动 Mihomo 隧道承载",
                "入",
                HealthLevel.Ok)
            : new MetricSnapshot(
                "TUN 路由",
                "检测到但未确认",
                "隧道路由仍存在，但未确认只有一个活动 Mihomo 核心；可能是残留或冲突路径",
                "入",
                HealthLevel.Warning);

    internal static MetricSnapshot DescribeSplitTunnelRoute() => new(
        "路由分流",
        "路径不一致",
        "不同公网目标或 IPv4 / IPv6 使用不同接口，可能是代理的规则分流；这不表示代理已关闭，也不能证明全部流量经过代理。断网保护状态请单独查看",
        "入",
        HealthLevel.Warning);

    internal static MetricSnapshot DescribeUnknownRoute() => new(
        "系统路由",
        "无法确认",
        "IP Helper 未能确认所有代表性公网前缀的路由；为避免漏报，不能排除未识别的直连路径",
        "入",
        HealthLevel.Warning);

    internal static (string Headline, string Detail)? DescribeDetectedSystemRoute(
        bool routeActive,
        bool systemProxyEnabled,
        bool otherTunnelDetected,
        string routeDetail,
        bool virtualNetworkDetected = false,
        bool splitTunnelDetected = false,
        bool routeLookupUnknown = false)
    {
        if (!routeActive) return null;
        if (routeLookupUnknown)
        {
            return (
                "系统路由状态无法确认",
                "IP Helper 未能确认所有代表性公网前缀的路由；为避免漏报，不能排除未识别的直连路径");
        }
        if (splitTunnelDetected)
        {
            return (
                "系统路由存在分流",
                "不同公网目标或 IPv4 / IPv6 使用不同接口，可能是规则分流；不能据此判定代理已关闭或已发生直连泄漏。断网保护状态独立显示");
        }
        if (virtualNetworkDetected)
        {
            return (
                "检测到虚拟网络路径",
                "系统最佳路由由虚拟 Ethernet 承载，但不能仅凭此判定为 VPN/TUN");
        }
        if (otherTunnelDetected)
        {
            return (
                "检测到其他 VPN/TUN",
                "系统存在活动隧道路由，但不能归因于 Mihomo；请以系统实际出口为准");
        }
        if (systemProxyEnabled)
        {
            return (
                "检测到系统代理路径",
                "系统代理已启用，但不是当前已确认的 Mihomo 入口；请以系统实际出口为准");
        }
        return ("检测到 TUN 路径", routeDetail);
    }

    internal static MetricSnapshot DescribeLocalPort(
        string host,
        int port,
        TcpListenerAttribution attribution,
        bool healthyMihomoTunRoute,
        bool alternateSystemPath = false) => attribution switch
        {
            TcpListenerAttribution.MihomoOwned => new MetricSnapshot(
                "本地端口",
                $"{port} 由 Mihomo 监听",
                LocalEndpointPolicy.FormatEndpoint(host, port),
                "端",
                HealthLevel.Ok),
            TcpListenerAttribution.OtherOrUnknown => new MetricSnapshot(
                "本地端口",
                $"{port} 监听者未归属",
                "端口可连接，但监听 PID 未归属于已检测的 Mihomo 进程",
                "端",
                HealthLevel.Warning),
            _ when healthyMihomoTunRoute => new MetricSnapshot(
                "本地端口",
                $"{port} 未监听",
                "已确认 Mihomo 代表性 TUN 路由；TUN-only 模式不要求 mixed 端口",
                "端",
                HealthLevel.Idle),
            _ when alternateSystemPath => new MetricSnapshot(
                "本地端口",
                "非当前入口",
                "已检测到不依赖此 Mihomo mixed 端口的系统代理或其他 VPN/TUN 路径",
                "端",
                HealthLevel.Idle),
            _ => new MetricSnapshot(
                "本地端口",
                $"{port} 未监听",
                "检查客户端 mixed 端口设置",
                "端",
                HealthLevel.Error)
        };

    internal static bool HasHealthyMihomoPath(
        int coreCount,
        TcpListenerAttribution portAttribution,
        TunnelKind tunnelKind) =>
        coreCount == 1 &&
        (portAttribution == TcpListenerAttribution.MihomoOwned ||
         tunnelKind == TunnelKind.Mihomo);

    internal IReadOnlySet<int> GetProxyCoreProcessIds()
    {
        var processIds = new HashSet<int>();
        foreach (var processName in CoreProcessNames)
        {
            Process[] processes = [];
            try
            {
                processes = Process.GetProcessesByName(processName);
                foreach (var process in processes)
                {
                    processIds.Add(process.Id);
                }
            }
            catch
            {
                // A protected process can disappear between enumeration calls.
            }
            finally
            {
                foreach (var process in processes)
                {
                    process.Dispose();
                }
            }
        }

        return processIds;
    }

    public int CountProxyCores() => GetProxyCoreProcessIds().Count;

    internal static string? DetectClientName(IEnumerable<string> processOrAdapterNames)
    {
        var labels = processOrAdapterNames.Select(value =>
        {
            if (value.Contains("v2rayn", StringComparison.OrdinalIgnoreCase)) return "v2rayN";
            if (value.Contains("ikuuu", StringComparison.OrdinalIgnoreCase)) return "iKuuuVPN";
            if (value.Contains("clash verge", StringComparison.OrdinalIgnoreCase) ||
                value.Contains("verge-mihomo", StringComparison.OrdinalIgnoreCase)) return "Clash Verge Rev";
            if (value.Contains("mihomo", StringComparison.OrdinalIgnoreCase) ||
                value.Contains("clash", StringComparison.OrdinalIgnoreCase)) return "Clash / Mihomo";
            if (value.Contains("sing-box", StringComparison.OrdinalIgnoreCase) ||
                value.Contains("singbox", StringComparison.OrdinalIgnoreCase)) return "sing-box";
            if (value.Contains("xray", StringComparison.OrdinalIgnoreCase)) return "Xray";
            if (value.Contains("v2ray", StringComparison.OrdinalIgnoreCase)) return "V2Ray";
            if (value.Contains("wireguard", StringComparison.OrdinalIgnoreCase)) return "WireGuard";
            if (value.Contains("openvpn", StringComparison.OrdinalIgnoreCase)) return "OpenVPN";
            if (value.Contains("tailscale", StringComparison.OrdinalIgnoreCase)) return "Tailscale";
            return null;
        }).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return labels.Length == 1 ? labels[0] : null;
    }

    internal static string? DetectRunningProxyClientName()
    {
        var processNames = new List<string>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try { processNames.Add(process.ProcessName); }
                catch { }
            }
        }
        return DetectClientName(processNames);
    }

    public async Task<bool> CanConnectAsync(
        string host,
        int port,
        int timeoutSeconds,
        CancellationToken cancellationToken = default)
    {
        if (!LocalEndpointPolicy.IsLoopbackHost(host) || port is < 1 or > 65535)
        {
            return false;
        }

        try
        {
            var address = IPAddress.Parse(LocalEndpointPolicy.NormalizeLoopbackHost(host));
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 30)));
            using var client = new TcpClient(address.AddressFamily);
            await client.ConnectAsync(address, port, timeout.Token);
            return client.Connected;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    public bool IsSystemProxyEnabled() => ReadSystemProxyConfiguration().Enabled;

    internal static SystemProxyConfiguration ParseSystemProxyConfiguration(
        int proxyEnable,
        string? proxyServer,
        string? autoConfigUrl,
        bool autoDetectEnabled = false,
        string? proxyBypass = null)
    {
        var explicitEnabled = proxyEnable == 1;
        string? host = null;
        int? port = null;
        var explicitCoversHttps = false;
        if (explicitEnabled && TryParseProxyEndpoint(
                proxyServer,
                out var parsedHost,
                out var parsedPort,
                out explicitCoversHttps))
        {
            host = LocalEndpointPolicy.IsLoopbackHost(parsedHost)
                ? LocalEndpointPolicy.NormalizeLoopbackHost(parsedHost)
                : parsedHost;
            port = parsedPort;
        }

        var pacUrl = string.IsNullOrWhiteSpace(autoConfigUrl) ? null : autoConfigUrl.Trim();
        var normalizedBypass = string.IsNullOrWhiteSpace(proxyBypass) ? null : proxyBypass.Trim();
        var (environmentProxyEnabled, environmentFingerprint) = ReadEnvironmentProxy();
        return new SystemProxyConfiguration(
            explicitEnabled,
            host,
            port,
            explicitCoversHttps,
            pacUrl is not null,
            pacUrl,
            autoDetectEnabled,
            normalizedBypass,
            environmentProxyEnabled,
            environmentFingerprint);
    }

    internal static SystemProxyConfiguration ReadSystemProxyConfiguration()
    {
        if (OperatingSystem.IsWindows() &&
            WinHttpGetIEProxyConfigForCurrentUser(out var ieConfig))
        {
            try
            {
                var proxy = Marshal.PtrToStringUni(ieConfig.Proxy);
                var autoConfigUrl = Marshal.PtrToStringUni(ieConfig.AutoConfigUrl);
                var proxyBypass = Marshal.PtrToStringUni(ieConfig.ProxyBypass);
                return ParseSystemProxyConfiguration(
                    string.IsNullOrWhiteSpace(proxy) ? 0 : 1,
                    proxy,
                    autoConfigUrl,
                    ieConfig.AutoDetect,
                    proxyBypass);
            }
            finally
            {
                FreeGlobalString(ieConfig.AutoConfigUrl);
                FreeGlobalString(ieConfig.Proxy);
                FreeGlobalString(ieConfig.ProxyBypass);
            }
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            return ParseSystemProxyConfiguration(
                Convert.ToInt32(key?.GetValue("ProxyEnable") ?? 0),
                Convert.ToString(key?.GetValue("ProxyServer")),
                Convert.ToString(key?.GetValue("AutoConfigURL")),
                proxyBypass: Convert.ToString(key?.GetValue("ProxyOverride")));
        }
        catch
        {
            var (environmentProxyEnabled, environmentFingerprint) = ReadEnvironmentProxy();
            return new SystemProxyConfiguration(
                false, null, null, false, false, null, false, null,
                environmentProxyEnabled, environmentFingerprint);
        }
    }

    internal static string ReadExitPathFingerprint()
    {
        try
        {
            var proxy = ReadSystemProxyConfiguration();
            var routes = GetBestRouteInterfaceIndexes();
            var adapters = NetworkInterface.GetAllNetworkInterfaces()
                .Where(adapter => adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .Select(adapter =>
                {
                    try
                    {
                        var properties = adapter.GetIPProperties();
                        var gateways = properties.GatewayAddresses
                            .Select(item => item.Address.ToString())
                            .Order(StringComparer.Ordinal);
                        var addresses = properties.UnicastAddresses
                            .Select(item => item.Address.ToString())
                            .Order(StringComparer.Ordinal);
                        return $"{adapter.Id}|{adapter.OperationalStatus}|{adapter.NetworkInterfaceType}|" +
                               $"{string.Join(",", gateways)}|{string.Join(",", addresses)}";
                    }
                    catch
                    {
                        return $"{adapter.Id}|unavailable";
                    }
                })
                .Order(StringComparer.Ordinal);
            var material = $"proxy={proxy}\nroute={routes}\nadapters={string.Join("\n", adapters)}";
            return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material)));
        }
        catch
        {
            return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("unavailable")));
        }
    }

    private static void FreeGlobalString(IntPtr memory)
    {
        if (memory != IntPtr.Zero)
        {
            _ = GlobalFree(memory);
        }
    }

    private static (bool Enabled, string? Fingerprint) ReadEnvironmentProxy()
    {
        var httpsProxy = Environment.GetEnvironmentVariable("HTTPS_PROXY");
        var allProxy = Environment.GetEnvironmentVariable("ALL_PROXY");
        var noProxy = Environment.GetEnvironmentVariable("NO_PROXY");
        var material = $"HTTPS_PROXY={httpsProxy}\nALL_PROXY={allProxy}\nNO_PROXY={noProxy}";
        var anyConfigured = !string.IsNullOrWhiteSpace(httpsProxy) || !string.IsNullOrWhiteSpace(allProxy);
        var anyRelevant = anyConfigured || !string.IsNullOrWhiteSpace(noProxy);
        return anyRelevant
            ? (anyConfigured, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(material))))
            : (false, null);
    }

    private static bool TryParseProxyEndpoint(
        string? raw,
        out string host,
        out int port,
        out bool coversHttps)
    {
        host = string.Empty;
        port = 0;
        coversHttps = false;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return false;
        }

        var entries = raw.Split(
            [';', ' ', '\t', '\r', '\n'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var ordered = entries
            .Where(entry => entry.StartsWith("https=", StringComparison.OrdinalIgnoreCase))
            .Concat(entries.Where(entry => !entry.Contains('=')))
            .Concat(entries.Where(entry => entry.StartsWith("http=", StringComparison.OrdinalIgnoreCase)));
        foreach (var entry in ordered)
        {
            var endpoint = entry.Contains('=') ? entry[(entry.IndexOf('=') + 1)..] : entry;
            var candidate = endpoint.Contains("://", StringComparison.Ordinal)
                ? endpoint
                : $"http://{endpoint}";
            if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
                string.IsNullOrWhiteSpace(uri.Host) || uri.Port is <= 0 or > 65535)
            {
                continue;
            }

            host = uri.Host;
            port = uri.Port;
            coversHttps = entry.StartsWith("https=", StringComparison.OrdinalIgnoreCase) ||
                          !entry.Contains('=');
            return true;
        }

        return false;
    }

    public async Task<bool> DetectTunAsync(CancellationToken cancellationToken = default)
        => (await DetectRouteAsync(cancellationToken)).MihomoDetected;

    internal static TunnelKind ClassifyTunnelAdapter(
        string name,
        string description,
        NetworkInterfaceType interfaceType = NetworkInterfaceType.Unknown,
        bool registryVirtual = false)
    {
        var combined = $"{name}\n{description}";
        if (MihomoTunKeywords.Any(keyword =>
                combined.Contains(keyword, StringComparison.OrdinalIgnoreCase)))
        {
            return TunnelKind.Mihomo;
        }
        if (interfaceType is NetworkInterfaceType.Ppp or NetworkInterfaceType.Tunnel ||
            OtherTunnelKeywords.Any(keyword =>
                combined.Contains(keyword, StringComparison.OrdinalIgnoreCase)))
        {
            return TunnelKind.Other;
        }
        return registryVirtual ? TunnelKind.VirtualNetwork : TunnelKind.None;
    }

    internal static TunnelKind CombineAdapterKinds(IEnumerable<TunnelKind> adapterKinds)
    {
        var kinds = adapterKinds.ToArray();
        if (kinds.Contains(TunnelKind.Split))
        {
            return TunnelKind.Split;
        }
        if (kinds.Contains(TunnelKind.Unknown))
        {
            return TunnelKind.Unknown;
        }
        if (kinds.Contains(TunnelKind.Other))
        {
            return TunnelKind.Other;
        }
        if (kinds.Contains(TunnelKind.VirtualNetwork))
        {
            return TunnelKind.VirtualNetwork;
        }
        return kinds.Contains(TunnelKind.Mihomo) ? TunnelKind.Mihomo : TunnelKind.None;
    }

    internal static TunnelKind ClassifyRoutedAdapterEvidence(
        BestRouteInterfaceIndexes bestRoutes,
        IEnumerable<RoutedAdapterEvidence> adapterEvidence)
    {
        if (bestRoutes.Ipv4Split || bestRoutes.Ipv6Split)
        {
            return TunnelKind.Split;
        }

        var evidence = adapterEvidence.ToArray();
        var ipv4Kind = ClassifyRouteFamily(
            bestRoutes.Ipv4,
            evidence,
            adapter => adapter.Ipv4Index,
            out var ipv4MappingUnknown);
        var ipv6Kind = ClassifyRouteFamily(
            bestRoutes.Ipv6,
            evidence,
            adapter => adapter.Ipv6Index,
            out var ipv6MappingUnknown);
        var knownResult = CombineRouteFamilies(ipv4Kind, ipv6Kind);
        if (!bestRoutes.Ipv4Unknown && !bestRoutes.Ipv6Unknown &&
            !ipv4MappingUnknown && !ipv6MappingUnknown)
        {
            return knownResult;
        }
        return knownResult == TunnelKind.None
            ? TunnelKind.Unknown
            : TunnelKind.Split;
    }

    private static TunnelKind? ClassifyRouteFamily(
        uint? bestRouteIndex,
        IEnumerable<RoutedAdapterEvidence> adapterEvidence,
        Func<RoutedAdapterEvidence, int?> interfaceIndex,
        out bool mappingUnknown)
    {
        mappingUnknown = false;
        if (bestRouteIndex is null)
        {
            return null;
        }

        var matchingAdapters = adapterEvidence
            .Where(adapter =>
            {
                var adapterIndex = interfaceIndex(adapter);
                return adapterIndex is > 0 &&
                    (uint)adapterIndex.Value == bestRouteIndex.Value;
            })
            .ToArray();
        if (matchingAdapters.Length == 0)
        {
            mappingUnknown = true;
            return null;
        }
        return CombineAdapterKinds(matchingAdapters.Select(adapter => adapter.Kind));
    }

    internal static TunnelKind CombineRouteFamilies(
        TunnelKind? ipv4Kind,
        TunnelKind? ipv6Kind)
    {
        if (ipv4Kind is null)
        {
            return ipv6Kind ?? TunnelKind.None;
        }
        if (ipv6Kind is null)
        {
            return ipv4Kind.Value;
        }
        return ipv4Kind == ipv6Kind
            ? ipv4Kind.Value
            : ipv4Kind == TunnelKind.None && ipv6Kind == TunnelKind.None
                ? TunnelKind.None
                : TunnelKind.Split;
    }

    internal static bool InterfaceCarriesBestRoute(
        int? ipv4Index,
        int? ipv6Index,
        BestRouteInterfaceIndexes bestRoutes) =>
        (ipv4Index is > 0 && bestRoutes.Ipv4 == (uint)ipv4Index.Value) ||
        (ipv6Index is > 0 && bestRoutes.Ipv6 == (uint)ipv6Index.Value);

    internal async Task<TunnelKind> DetectTunnelKindAsync(CancellationToken cancellationToken = default) =>
        (await DetectRouteAsync(cancellationToken)).Coverage;

    internal Task<RouteDetection> DetectRouteAsync(
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows())
        {
            return Task.FromResult(new RouteDetection(TunnelKind.None, false, false));
        }

        var ipv4 = BestRouteProbeIpv4.Select(LookupBestRouteInterface).ToArray();
        var ipv6 = BestRouteProbeIpv6.Select(LookupBestRouteInterface).ToArray();
        cancellationToken.ThrowIfCancellationRequested();
        var evidence = new List<RoutedAdapterEvidence>();
        try
        {
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                var (ipv4Index, ipv6Index) = ReadInterfaceIndexes(adapter);
                var carriesBestRoute =
                    (ipv4Index is > 0 && ipv4.Any(route => route.InterfaceIndex == (uint)ipv4Index)) ||
                    (ipv6Index is > 0 && ipv6.Any(route => route.InterfaceIndex == (uint)ipv6Index));
                var adapterKind = ClassifyTunnelAdapter(
                    adapter.Name,
                    adapter.Description,
                    adapter.NetworkInterfaceType,
                    registryVirtual: carriesBestRoute && IsRegistryVirtualAdapter(adapter.Id));
                evidence.Add(new RoutedAdapterEvidence(
                    adapterKind,
                    ipv4Index,
                    ipv6Index,
                    DetectClientName([adapter.Name, adapter.Description])));
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return Task.FromResult(new RouteDetection(TunnelKind.Unknown, false, false, true));
        }

        return Task.FromResult(AnalyzeRoutes(ipv4, ipv6, evidence));
    }

    internal static RouteDetection AnalyzeRoutes(IReadOnlyList<BestRouteLookup> ipv4,
        IReadOnlyList<BestRouteLookup> ipv6, IEnumerable<RoutedAdapterEvidence> adapters)
    {
        var evidence = adapters.ToArray();
        var bestRoutes = BuildBestRouteIndexes(ipv4, ipv6);
        // Use individual successful lookups, not the aggregate's null index on
        // split/partial failure. An idle adapter is never evidence of a VPN path.
        var routed = evidence.Where(adapter =>
            (adapter.Ipv4Index is > 0 && ipv4.Any(route => route.InterfaceIndex == (uint)adapter.Ipv4Index)) ||
            (adapter.Ipv6Index is > 0 && ipv6.Any(route => route.InterfaceIndex == (uint)adapter.Ipv6Index))).ToArray();
        var unmapped = ipv4.Any(route => route.InterfaceIndex is { } index &&
            !evidence.Any(adapter => adapter.Ipv4Index == index)) ||
            ipv6.Any(route => route.InterfaceIndex is { } index &&
            !evidence.Any(adapter => adapter.Ipv6Index == index));
        return new RouteDetection(ClassifyRoutedAdapterEvidence(bestRoutes, evidence),
            routed.Any(adapter => adapter.Kind == TunnelKind.Mihomo),
            routed.Any(adapter => adapter.Kind == TunnelKind.Other),
            bestRoutes.Ipv4Unknown || bestRoutes.Ipv6Unknown || unmapped,
            DetectClientName(routed.Select(adapter => adapter.ClientName ?? string.Empty)));
    }

    private static BestRouteInterfaceIndexes BuildBestRouteIndexes(
        IEnumerable<BestRouteLookup> ipv4Lookups, IEnumerable<BestRouteLookup> ipv6Lookups)
    {
        var ipv4 = AggregateBestRouteLookups(ipv4Lookups);
        var ipv6 = AggregateBestRouteLookups(ipv6Lookups);
        return new BestRouteInterfaceIndexes(ipv4.InterfaceIndex, ipv6.InterfaceIndex,
            ipv4.Unknown, ipv6.Unknown, ipv4.Split, ipv6.Split);
    }

    internal static BestRouteInterfaceIndexes GetBestRouteInterfaceIndexes()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new BestRouteInterfaceIndexes(null, null);
        }

        var ipv4 = AggregateBestRouteLookups(
            BestRouteProbeIpv4.Select(LookupBestRouteInterface));
        var ipv6 = AggregateBestRouteLookups(
            BestRouteProbeIpv6.Select(LookupBestRouteInterface));
        return new BestRouteInterfaceIndexes(
            ipv4.InterfaceIndex,
            ipv6.InterfaceIndex,
            ipv4.Unknown,
            ipv6.Unknown,
            ipv4.Split,
            ipv6.Split);
    }

    internal static BestRouteLookup AggregateBestRouteLookups(
        IEnumerable<BestRouteLookup> lookups)
    {
        var results = lookups.ToArray();
        if (results.Length == 0 || results.Any(result => result.Unknown))
        {
            return BestRouteLookup.Failed();
        }
        if (results.Any(result => result.Split))
        {
            return BestRouteLookup.Inconsistent();
        }

        var resolvedIndexes = results
            .Where(result => result.InterfaceIndex is not null)
            .Select(result => result.InterfaceIndex!.Value)
            .Distinct()
            .ToArray();
        if (resolvedIndexes.Length == 0)
        {
            return BestRouteLookup.Unavailable();
        }
        if (resolvedIndexes.Length != 1 ||
            results.Any(result => result.InterfaceIndex is null))
        {
            return BestRouteLookup.Inconsistent();
        }
        return BestRouteLookup.Resolved(resolvedIndexes[0]);
    }

    private static BestRouteLookup LookupBestRouteInterface(IPAddress destination)
    {
        try
        {
            var socketAddress = new IPEndPoint(destination, 0).Serialize();
            var bytes = new byte[socketAddress.Size];
            for (var index = 0; index < socketAddress.Size; index++)
            {
                bytes[index] = socketAddress[index];
            }

            var nativeAddress = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, nativeAddress, bytes.Length);
                var result = GetBestInterfaceEx(nativeAddress, out var bestInterfaceIndex);
                return InterpretBestRouteResult(result, bestInterfaceIndex);
            }
            finally
            {
                Marshal.FreeHGlobal(nativeAddress);
            }
        }
        catch (DllNotFoundException)
        {
            return BestRouteLookup.Failed();
        }
        catch (EntryPointNotFoundException)
        {
            return BestRouteLookup.Failed();
        }
        catch (BadImageFormatException)
        {
            return BestRouteLookup.Failed();
        }
        catch (SEHException)
        {
            return BestRouteLookup.Failed();
        }
    }

    internal static BestRouteLookup InterpretBestRouteResult(
        uint result,
        uint bestInterfaceIndex) =>
        result == NoError && bestInterfaceIndex != 0
            ? BestRouteLookup.Resolved(bestInterfaceIndex)
            : result == ErrorNotSupported
                ? BestRouteLookup.Unavailable()
                : BestRouteLookup.Failed();

    internal static bool TryGetBestRouteInterfaceIndex(
        IPAddress destination,
        out uint bestInterfaceIndex)
    {
        ArgumentNullException.ThrowIfNull(destination);
        bestInterfaceIndex = 0;
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        var result = LookupBestRouteInterface(destination);
        if (result.InterfaceIndex is { } interfaceIndex)
        {
            bestInterfaceIndex = interfaceIndex;
            return true;
        }
        return false;
    }

    private static (int? Ipv4Index, int? Ipv6Index) ReadInterfaceIndexes(
        NetworkInterface adapter)
    {
        int? ipv4Index = null;
        int? ipv6Index = null;
        try
        {
            var properties = adapter.GetIPProperties();
            ipv4Index = properties.GetIPv4Properties()?.Index;
            ipv6Index = properties.GetIPv6Properties()?.Index;
        }
        catch
        {
            // An adapter can disappear while its properties are being read.
        }
        return (ipv4Index, ipv6Index);
    }

    private static bool IsRegistryVirtualAdapter(string adapterId)
    {
        try
        {
            using var adapterClass = Registry.LocalMachine.OpenSubKey(NetworkAdapterClassPath);
            if (adapterClass is null)
            {
                return false;
            }

            var normalizedAdapterId = NormalizeAdapterId(adapterId);
            foreach (var subKeyName in adapterClass.GetSubKeyNames())
            {
                using var adapterKey = adapterClass.OpenSubKey(subKeyName);
                var registeredId = Convert.ToString(adapterKey?.GetValue("NetCfgInstanceId"));
                if (!string.Equals(
                        NormalizeAdapterId(registeredId),
                        normalizedAdapterId,
                        StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                return (ReadRegistryFlags(adapterKey?.GetValue("Characteristics")) & NcfVirtual) != 0;
            }
        }
        catch
        {
            // Registry evidence is optional and must fail closed.
        }
        return false;
    }

    private static string NormalizeAdapterId(string? adapterId) =>
        (adapterId ?? string.Empty).Trim().Trim('{', '}');

    private static uint ReadRegistryFlags(object? value) => value switch
    {
        int signed => unchecked((uint)signed),
        uint unsigned => unsigned,
        long signed => unchecked((uint)signed),
        ulong unsigned => unchecked((uint)unsigned),
        _ => 0
    };
}
