using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using PuffRoute.Models;

namespace PuffRoute.Services;

public sealed class HealthCheckService
{
    private static readonly (string Name, string Url)[] IpServices =
    [
        ("ipify", "https://api.ipify.org"),
        ("ifconfig.me", "https://ifconfig.me/ip"),
        ("ip.sb", "https://ip.sb/ip")
    ];

    private static readonly (string Name, string Url)[] SiteChecks =
    [
        ("OpenAI API", "https://api.openai.com"),
        ("Anthropic API", "https://api.anthropic.com"),
        ("ChatGPT", "https://chatgpt.com"),
        ("Claude", "https://claude.ai"),
        ("Gemini API", "https://generativelanguage.googleapis.com")
    ];

    private readonly ProxyProbeService _probeService;

    public HealthCheckService(ProxyProbeService probeService)
    {
        _probeService = probeService;
    }

    public async Task<HealthReport> RunAsync(AppConfig config, CancellationToken cancellationToken = default)
    {
        var snapshot = await _probeService.ProbeAsync(config, cancellationToken);
        var localItems = new List<HealthCheckItem>
        {
            new("代理核心", snapshot.Core.Value, snapshot.Core.Level == HealthLevel.Ok),
            new("本地混合端口", $"{config.MixedHost}:{config.MixedPort} · {snapshot.Port.Value}", snapshot.Port.Level == HealthLevel.Ok),
            new("流量入口", snapshot.Route.Value, snapshot.SystemProxyEnabled || snapshot.TunDetected)
        };

        using var handler = new SocketsHttpHandler
        {
            Proxy = new WebProxy(new Uri($"http://{config.MixedHost}:{config.MixedPort}")),
            UseProxy = true,
            ConnectTimeout = TimeSpan.FromSeconds(config.TimeoutSeconds)
        };
        using var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(config.TimeoutSeconds)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("PuffRoute/1.0");

        var exitItem = await CheckExitIpAsync(client, config, cancellationToken);
        var siteTasks = SiteChecks.Select(site => CheckSiteAsync(client, site.Name, site.Url, cancellationToken));
        var siteItems = await Task.WhenAll(siteTasks);
        var internetItem = await CheckGenerate204Async(client, cancellationToken);

        return new HealthReport
        {
            CheckedAt = DateTime.Now,
            Sections =
            [
                new HealthCheckSection("本地代理", localItems),
                new HealthCheckSection("代理出口", [exitItem]),
                new HealthCheckSection("常用站点", siteItems),
                new HealthCheckSection("外网连通性", [internetItem])
            ]
        };
    }

    private static async Task<HealthCheckItem> CheckExitIpAsync(
        HttpClient client,
        AppConfig config,
        CancellationToken cancellationToken)
    {
        foreach (var service in IpServices)
        {
            try
            {
                var value = (await client.GetStringAsync(service.Url, cancellationToken)).Trim();
                if (!IPAddress.TryParse(value, out _))
                {
                    continue;
                }

                if (string.IsNullOrWhiteSpace(config.ExpectedIp))
                {
                    return new HealthCheckItem("出口 IP", $"{value} · 未设置期望值", true);
                }

                var matched = string.Equals(value, config.ExpectedIp.Trim(), StringComparison.OrdinalIgnoreCase);
                return new HealthCheckItem(
                    "出口 IP",
                    matched ? $"{value} · 符合配置" : $"{value} · 期望 {config.ExpectedIp.Trim()}",
                    matched);
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
            {
                // Try the next public IP service through the same proxy.
            }
        }

        return new HealthCheckItem("出口 IP", "无法通过本地代理获取出口地址", false);
    }

    private static async Task<HealthCheckItem> CheckSiteAsync(
        HttpClient client,
        string name,
        string url,
        CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            var code = (int)response.StatusCode;
            return new HealthCheckItem(name, $"HTTP {code} · 网络可达", true);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
        {
            return new HealthCheckItem(name, "TCP、DNS 或 TLS 连接失败", false);
        }
    }

    private static async Task<HealthCheckItem> CheckGenerate204Async(
        HttpClient client,
        CancellationToken cancellationToken)
    {
        try
        {
            using var response = await client.GetAsync(
                "https://www.google.com/generate_204",
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            var code = (int)response.StatusCode;
            return new HealthCheckItem(
                "Google 204 探测",
                code == 204 ? "HTTP 204 · 代理出网正常" : $"HTTP {code} · 已连接但响应异常",
                code == 204);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
        {
            return new HealthCheckItem("Google 204 探测", "无法通过代理连接外网", false);
        }
    }
}
