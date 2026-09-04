using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

internal enum HealthExitRoute
{
    Unavailable,
    MihomoMixed,
    TunSystem,
    SystemRoute
}

public sealed class HealthCheckService
{
    private static readonly (string Name, string Url)[] IpServices =
    [
        ("ipify", "https://api.ipify.org"),
        ("ifconfig.me", "https://ifconfig.me/ip"),
        ("ip.sb", "https://ip.sb/ip")
    ];

    private readonly ProxyProbeService _probeService;
    private readonly MihomoPlanInspectionService _planInspectionService;

    public HealthCheckService(
        ProxyProbeService probeService,
        MihomoPlanInspectionService planInspectionService)
    {
        _probeService = probeService;
        _planInspectionService = planInspectionService;
    }

    public async Task<HealthReport> RunAsync(AppConfig config, CancellationToken cancellationToken = default)
    {
        using var overallTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        overallTimeout.CancelAfter(CalculateOverallTimeout(config.TimeoutSeconds));
        try
        {
            return await RunCoreAsync(config, overallTimeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new HealthReport
            {
                CheckedAt = DateTime.Now,
                PlanName = config.SecondaryEnabled
                    ? $"通用检测 + {config.SecondaryLabel}"
                    : "通用检测",
                Sections =
                [
                    new HealthCheckSection(
                        "检测未完成",
                        [new HealthCheckItem(
                            "总超时",
                            "检测未在安全时限内结束；未返回的项目不得视为通过",
                            HealthLevel.Error)],
                        100,
                        IsCritical: true)
                ]
            };
        }
    }

    internal static TimeSpan CalculateOverallTimeout(int timeoutSeconds) =>
        TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 3, 30) * 5 + 15);

    private async Task<HealthReport> RunCoreAsync(
        AppConfig config,
        CancellationToken cancellationToken)
    {
        var snapshot = await _probeService.ProbeAsync(config, cancellationToken);
        var entryLevel = snapshot.Route.Level == HealthLevel.Idle
            ? HealthLevel.Error
            : snapshot.Route.Level;
        var localItems = new List<HealthCheckItem>
        {
            new("代理核心", snapshot.Core.Value, snapshot.Core.Level),
            new(
                "本地混合端口",
                $"{LocalEndpointPolicy.FormatEndpoint(config.MixedHost, config.MixedPort)} · {snapshot.Port.Value}",
                snapshot.Port.Level),
            new("流量入口", $"{snapshot.Route.Title} · {snapshot.Route.Value}", entryLevel)
        };
        if (snapshot.TunDetected)
        {
            localItems.Add(await CheckFakeIpDnsAsync(config.TimeoutSeconds, cancellationToken));
        }

        var exitResult = await CheckPrimaryExitAsync(snapshot, config, cancellationToken);
        if (!config.SecondaryEnabled)
        {
            return new HealthReport
            {
                CheckedAt = DateTime.Now,
                PlanName = "通用检测",
                Sections =
                [
                    new HealthCheckSection("本地代理", localItems, 45, IsCritical: true),
                    new HealthCheckSection("代理出口", [exitResult.Item], 45, IsCritical: true),
                    CreateBoundarySection(10)
                ]
            };
        }

        var planItems = (await _planInspectionService.InspectAsync(config, cancellationToken)).ToList();
        cancellationToken.ThrowIfCancellationRequested();
        var secondaryPortAttribution = await TcpListenerOwnership.ProbeAsync(
            config.SecondaryMixedHost,
            config.SecondaryMixedPort,
            _probeService.GetProxyCoreProcessIds(),
            config.TimeoutSeconds,
            cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var secondaryPortOwnedByMihomo =
            secondaryPortAttribution == TcpListenerAttribution.MihomoOwned;
        planItems.Insert(0, secondaryPortAttribution switch
        {
            TcpListenerAttribution.MihomoOwned => new HealthCheckItem(
                "额外混合端口",
                $"{LocalEndpointPolicy.FormatEndpoint(config.SecondaryMixedHost, config.SecondaryMixedPort)} 由 Mihomo 监听",
                HealthLevel.Ok),
            TcpListenerAttribution.OtherOrUnknown => new HealthCheckItem(
                "额外混合端口",
                $"{LocalEndpointPolicy.FormatEndpoint(config.SecondaryMixedHost, config.SecondaryMixedPort)} 可连接，但监听 PID 未归属 Mihomo",
                HealthLevel.Error),
            _ => new HealthCheckItem(
                "额外混合端口",
                $"{LocalEndpointPolicy.FormatEndpoint(config.SecondaryMixedHost, config.SecondaryMixedPort)} 未监听",
                HealthLevel.Error)
        });

        (HealthCheckItem Item, string? Address) secondaryExit;
        if (secondaryPortOwnedByMihomo)
        {
            using var secondaryClient = CreateProxyClient(
                config.SecondaryMixedHost,
                config.SecondaryMixedPort,
                config.TimeoutSeconds);
            secondaryExit = await CheckExitIpAsync(
                secondaryClient,
                config.ExpectedSecondaryIp,
                config.SecondaryLabel,
                cancellationToken);
        }
        else
        {
            secondaryExit = (new HealthCheckItem(
                "额外出口",
                secondaryPortAttribution == TcpListenerAttribution.OtherOrUnknown
                    ? "额外入口未归属于 Mihomo，未发送出口查询"
                    : "本地额外入口不可用，未发送出口查询",
                HealthLevel.Error), null);
        }

        var exitComparison = exitResult.Address is not null && secondaryExit.Address is not null
            ? ExitSummary.AreEquivalentPublicAddresses(exitResult.Address, secondaryExit.Address)
                ? new HealthCheckItem("出口结论", "额外入口与默认入口返回相同公网出口", HealthLevel.Warning)
                : new HealthCheckItem("出口结论", "默认入口与额外入口返回不同公网出口", HealthLevel.Ok)
            : new HealthCheckItem("出口结论", "出口数据不足，暂时无法比较", HealthLevel.Warning);

        return new HealthReport
        {
            CheckedAt = DateTime.Now,
            PlanName = $"通用检测 + {config.SecondaryLabel}",
            Sections =
            [
                new HealthCheckSection("本地代理", localItems, 30, IsCritical: true),
                new HealthCheckSection("默认出口", [exitResult.Item], 20, IsCritical: true),
                new HealthCheckSection($"{config.SecondaryLabel} · 策略与规则", planItems, 20, IsCritical: true),
                new HealthCheckSection(
                    $"{config.SecondaryLabel} · 实际出口",
                    [secondaryExit.Item, exitComparison],
                    20,
                    IsCritical: true),
                CreateBoundarySection(10)
            ]
        };
    }

    private static HealthCheckSection CreateBoundarySection(int weight) =>
        new("检测边界（默认低风险模式）",
        [
            new HealthCheckItem(
                "主动平台探测",
                "已关闭 · 不请求 Claude、ChatGPT 或 Gemini 网页与 API",
                HealthLevel.Ok)
        ], weight);

    private static HttpClient CreateProxyClient(string host, int port, int timeoutSeconds)
    {
        if (!LocalEndpointPolicy.IsLoopbackHost(host) || port is < 1 or > 65535)
        {
            throw new InvalidOperationException("ProxyGauge 只允许通过本机回环代理执行检测。");
        }

        var handler = new SocketsHttpHandler
        {
            Proxy = new WebProxy(new UriBuilder(Uri.UriSchemeHttp, host.Trim('[', ']'), port).Uri),
            UseProxy = true,
            UseCookies = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        return client;
    }

    internal static bool ShouldUseTunOnlySystemRoute(ProxySnapshot snapshot) =>
        snapshot.TunDetected &&
        !snapshot.SplitTunnelDetected && !snapshot.RouteLookupUnknown &&
        snapshot.Core.Level == HealthLevel.Ok &&
        snapshot.Port.Level != HealthLevel.Ok &&
        !snapshot.SystemProxyEnabled;

    internal static HealthExitRoute SelectPrimaryExitRoute(ProxySnapshot snapshot) =>
        snapshot.OtherTunnelDetected || (snapshot.TunDetected &&
            (snapshot.SplitTunnelDetected || snapshot.RouteLookupUnknown))
            ? HealthExitRoute.SystemRoute
            : ShouldUseTunOnlySystemRoute(snapshot)
            ? HealthExitRoute.TunSystem
            : snapshot.Port.Level == HealthLevel.Ok
                ? HealthExitRoute.MihomoMixed
                : HealthExitRoute.Unavailable;

    private static async Task<(HealthCheckItem Item, string? Address)> CheckPrimaryExitAsync(
        ProxySnapshot snapshot,
        AppConfig config,
        CancellationToken cancellationToken)
    {
        var route = SelectPrimaryExitRoute(snapshot);
        if (route == HealthExitRoute.Unavailable)
        {
            return (new HealthCheckItem(
                "出口 IP",
                "mixed 端点未确认由 Mihomo 监听，且未确认可用的 TUN-only 路径；未发送出口查询",
                HealthLevel.Error), null);
        }

        using var client = route == HealthExitRoute.SystemRoute
            ? CreateSystemRouteClient(config.TimeoutSeconds)
            : route == HealthExitRoute.TunSystem
            ? CreateTunRouteClient(config.TimeoutSeconds)
            : CreateProxyClient(config.MixedHost, config.MixedPort, config.TimeoutSeconds);
        var result = await CheckExitIpAsync(
            client,
            config.ExpectedIp,
            route is HealthExitRoute.TunSystem or HealthExitRoute.SystemRoute ? "系统实际出口" : "默认出口",
            cancellationToken);
        if (route == HealthExitRoute.SystemRoute)
        {
            result.Item = result.Item with
            {
                Detail = result.Item.Detail + " · 仅验证本次系统路径的查询结果，不代表全部流量经过 VPN；规则分流与断网保护独立判断"
            };
        }
        return result;
    }

    private static HttpClient CreateSystemRouteClient(int timeoutSeconds) => new(new SocketsHttpHandler
    {
        Proxy = HttpClient.DefaultProxy,
        UseProxy = true,
        UseCookies = false,
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds)
    }) { Timeout = TimeSpan.FromSeconds(timeoutSeconds) };

    private static HttpClient CreateTunRouteClient(int timeoutSeconds)
    {
        var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            UseCookies = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        return new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
    }

    private static async Task<(HealthCheckItem Item, string? Address)> CheckExitIpAsync(
        HttpClient client,
        string expectedIp,
        string label,
        CancellationToken cancellationToken)
    {
        var queried = await Task.WhenAll(IpServices.Select(service =>
            TryQueryIpServiceAsync(client, service, cancellationToken)));
        var results = queried.Where(result => result is not null)
            .Select(result => result!.Value)
            .ToArray();

        if (results.Length == 0)
        {
            return (new HealthCheckItem("出口 IP", "三个查询源均无法通过当前检测路径获取出口地址", false), null);
        }

        var address = ExitSummary.SelectConsensusAddress(results.Select(result => result.Address));
        var sourceSummary = string.Join(" · ", results.Select(result => $"{result.Name} {result.Address}"));
        var hasConflict = results.Select(result => result.Address).Distinct(StringComparer.Ordinal).Count() > 1;
        var insufficient = results.Length < 2;
        var expected = expectedIp.Trim();
        var invalidExpected = expected.Length > 0 &&
            !ExitSummary.TryNormalizePublicAddress(expected, out _);
        var hasExpected = ExitSummary.TryNormalizePublicAddress(expected, out var normalizedExpected);
        var expectedMismatch = address is not null && hasExpected &&
            !string.Equals(address, normalizedExpected, StringComparison.Ordinal);

        var level = invalidExpected
            ? HealthLevel.Error
            : address is null
            ? HealthLevel.Warning
            : expectedMismatch
            ? HealthLevel.Error
            : hasConflict || insufficient ? HealthLevel.Warning : HealthLevel.Ok;
        var verdict = invalidExpected
            ? "配置的期望出口不是规范公网地址，请在设置中修正"
            : address is null && results.Length == 1
            ? "只收到一个查询源响应，不作为高置信主结果"
            : address is null
            ? "查询结果平票或互相冲突，未选择任意地址作为主结果"
            : expectedMismatch
            ? $"主结果 {address} · 期望 {expected}"
            : hasConflict
                ? $"多数结果为 {address}，部分查询源不一致"
                : insufficient
                    ? "只收到一个查询源响应，暂时无法交叉验证"
                    : $"{results.Length} 个查询源确认出口一致 ({address})";
        return (new HealthCheckItem($"{label} · 出口一致性", $"{verdict} · {sourceSummary}", level), address);
    }

    private static async Task<(string Name, string Address)?> TryQueryIpServiceAsync(
        HttpClient client,
        (string Name, string Url) service,
        CancellationToken cancellationToken)
    {
        try
        {
            var value = (await ExitSummaryService.GetNoCacheStringAsync(
                client,
                service.Url,
                client.Timeout,
                cancellationToken)).Trim();
            return ExitSummary.TryNormalizePublicAddress(value, out var normalized)
                ? (service.Name, normalized)
                : null;
        }
        catch (Exception exception) when (
            !cancellationToken.IsCancellationRequested &&
            exception is HttpRequestException or OperationCanceledException or IOException)
        {
            return null;
        }
    }

    private static async Task<HealthCheckItem> CheckFakeIpDnsAsync(
        int timeoutSeconds,
        CancellationToken cancellationToken)
    {
        using var dnsTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        dnsTimeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 3, 30)));
        try
        {
            var addresses = await Dns.GetHostAddressesAsync("www.cloudflare.com", dnsTimeout.Token);
            var first = addresses.FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork);
            if (first is null)
            {
                return new HealthCheckItem("TUN DNS", "没有取得 IPv4 解析结果，请检查 dns-hijack 与 dns 配置", HealthLevel.Error);
            }

            var bytes = first.GetAddressBytes();
            return bytes.Length == 4 && bytes[0] == 198 && bytes[1] == 18
                ? new HealthCheckItem("TUN DNS", $"{first} · Fake-IP 生效，域名分流可用", HealthLevel.Ok)
                : new HealthCheckItem("TUN DNS", $"{first} · 返回真实地址，DOMAIN 规则可能无法按预期命中", HealthLevel.Warning);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new HealthCheckItem("TUN DNS", "DNS 查询超时，请检查 dns-hijack 与系统解析器", HealthLevel.Error);
        }
        catch (SocketException)
        {
            return new HealthCheckItem("TUN DNS", "系统无法解析域名，请检查 dns-hijack 与 dns 配置", HealthLevel.Error);
        }
    }

}
