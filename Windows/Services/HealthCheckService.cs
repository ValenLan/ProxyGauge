using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

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
        var snapshot = await _probeService.ProbeAsync(config, cancellationToken);
        var entryLevel = snapshot.SystemProxyEnabled && snapshot.TunDetected
            ? HealthLevel.Warning
            : snapshot.SystemProxyEnabled || snapshot.TunDetected
                ? HealthLevel.Ok
                : HealthLevel.Error;
        var localItems = new List<HealthCheckItem>
        {
            new("代理核心", snapshot.Core.Value, snapshot.Core.Level),
            new("本地混合端口", $"{config.MixedHost}:{config.MixedPort} · {snapshot.Port.Value}", snapshot.Port.Level),
            new("流量入口", $"{snapshot.Route.Title} · {snapshot.Route.Value}", entryLevel)
        };
        if (snapshot.TunDetected)
        {
            localItems.Add(await CheckFakeIpDnsAsync(cancellationToken));
        }

        using var client = CreateProxyClient(config.MixedHost, config.MixedPort, config.TimeoutSeconds);
        var exitResult = await CheckExitIpAsync(
            client,
            config.ExpectedIp,
            "默认出口",
            cancellationToken);
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
        var secondaryPortOpen = await _probeService.CanConnectAsync(
            config.SecondaryMixedHost,
            config.SecondaryMixedPort,
            config.TimeoutSeconds,
            cancellationToken);
        planItems.Insert(0, secondaryPortOpen
            ? new HealthCheckItem(
                "额外混合端口",
                $"{config.SecondaryMixedHost}:{config.SecondaryMixedPort} 正在监听",
                HealthLevel.Ok)
            : new HealthCheckItem(
                "额外混合端口",
                $"{config.SecondaryMixedHost}:{config.SecondaryMixedPort} 未监听",
                HealthLevel.Error));

        (HealthCheckItem Item, string? Address) secondaryExit;
        if (secondaryPortOpen)
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
                "本地额外入口不可用，未发送出口查询",
                HealthLevel.Error), null);
        }

        var exitComparison = exitResult.Address is not null && secondaryExit.Address is not null
            ? string.Equals(exitResult.Address, secondaryExit.Address, StringComparison.OrdinalIgnoreCase)
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

    public static async Task<string?> ResolveDefaultExitIpAsync(
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        using var client = CreateProxyClient(config.MixedHost, config.MixedPort, config.TimeoutSeconds);
        foreach (var service in IpServices)
        {
            try
            {
                var value = (await client.GetStringAsync(service.Url, cancellationToken)).Trim();
                if (IPAddress.TryParse(value, out _))
                {
                    return value;
                }
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
            {
                // Fall back to the next independent lookup through the same local proxy.
            }
        }

        return null;
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
            ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(timeoutSeconds)
        };
        return client;
    }

    private static async Task<(HealthCheckItem Item, string? Address)> CheckExitIpAsync(
        HttpClient client,
        string expectedIp,
        string label,
        CancellationToken cancellationToken)
    {
        var results = new List<(string Name, string Address)>();
        foreach (var service in IpServices)
        {
            try
            {
                var value = (await client.GetStringAsync(service.Url, cancellationToken)).Trim();
                if (!IPAddress.TryParse(value, out _)) continue;
                results.Add((service.Name, value));
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
            {
                // Keep collecting independent public IP results through the same proxy.
            }
        }

        if (results.Count == 0)
        {
            return (new HealthCheckItem("出口 IP", "三个查询源均无法通过本地代理获取出口地址", false), null);
        }

        var groups = results
            .GroupBy(result => result.Address, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(group => group.Count())
            .ToArray();
        var address = groups[0].Key;
        var sourceSummary = string.Join(" · ", results.Select(result => $"{result.Name} {result.Address}"));
        var hasConflict = groups.Length > 1;
        var insufficient = results.Count < 2;
        var expected = expectedIp.Trim();
        var expectedMismatch = !string.IsNullOrWhiteSpace(expected) &&
            !string.Equals(address, expected, StringComparison.OrdinalIgnoreCase);

        var level = expectedMismatch
            ? HealthLevel.Error
            : hasConflict || insufficient ? HealthLevel.Warning : HealthLevel.Ok;
        var verdict = expectedMismatch
            ? $"主结果 {address} · 期望 {expected}"
            : hasConflict
                ? "查询结果不一致，可能发生节点轮换、分流或透明代理干扰"
                : insufficient
                    ? "只收到一个查询源响应，暂时无法交叉验证"
                    : $"{results.Count} 个查询源确认出口一致 ({address})";
        return (new HealthCheckItem($"{label} · 出口一致性", $"{verdict} · {sourceSummary}", level), address);
    }

    private static async Task<HealthCheckItem> CheckFakeIpDnsAsync(CancellationToken cancellationToken)
    {
        try
        {
            var addresses = await Dns.GetHostAddressesAsync("www.cloudflare.com", cancellationToken);
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
        catch (Exception exception) when (exception is SocketException or OperationCanceledException)
        {
            return new HealthCheckItem("TUN DNS", "系统无法解析域名，请检查 dns-hijack 与 dns 配置", HealthLevel.Error);
        }
    }

}
