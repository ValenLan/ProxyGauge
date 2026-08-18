using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;
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
        client.DefaultRequestHeaders.UserAgent.ParseAdd("PuffRoute/1.1");

        var exitResult = await CheckExitIpAsync(client, config, cancellationToken);
        var riskTask = CheckIpRiskAsync(client, exitResult.Address, cancellationToken);
        var siteTasks = SiteChecks.Select(site => CheckSiteAsync(client, site.Name, site.Url, cancellationToken));
        var internetTask = CheckGenerate204Async(client, cancellationToken);

        var riskItems = await riskTask;
        var siteItems = await Task.WhenAll(siteTasks);
        var internetItem = await internetTask;

        return new HealthReport
        {
            CheckedAt = DateTime.Now,
            Sections =
            [
                new HealthCheckSection("本地代理", localItems),
                new HealthCheckSection("代理出口", [exitResult.Item]),
                new HealthCheckSection("IP 风险画像", riskItems),
                new HealthCheckSection("常用站点", siteItems),
                new HealthCheckSection("外网连通性", [internetItem])
            ]
        };
    }

    private static async Task<(HealthCheckItem Item, string? Address)> CheckExitIpAsync(
        HttpClient client,
        AppConfig config,
        CancellationToken cancellationToken)
    {
        foreach (var service in IpServices)
        {
            try
            {
                var value = (await client.GetStringAsync(service.Url, cancellationToken)).Trim();
                if (!IPAddress.TryParse(value, out _)) continue;

                if (string.IsNullOrWhiteSpace(config.ExpectedIp))
                {
                    return (new HealthCheckItem("出口 IP", $"{value} · 未设置期望值", true), value);
                }

                var matched = string.Equals(value, config.ExpectedIp.Trim(), StringComparison.OrdinalIgnoreCase);
                return (
                    new HealthCheckItem(
                        "出口 IP",
                        matched ? $"{value} · 符合配置" : $"{value} · 期望 {config.ExpectedIp.Trim()}",
                        matched),
                    value);
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
            {
                // Try the next public IP service through the same proxy.
            }
        }

        return (new HealthCheckItem("出口 IP", "无法通过本地代理获取出口地址", false), null);
    }

    private static async Task<IReadOnlyList<HealthCheckItem>> CheckIpRiskAsync(
        HttpClient client,
        string? address,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(address))
        {
            return [new HealthCheckItem("风险画像", "未取得出口 IP，暂时无法查询", HealthLevel.Idle)];
        }

        var escaped = Uri.EscapeDataString(address);
        var ipApiTask = TryGetStringAsync(client, $"https://api.ipapi.is/?q={escaped}", cancellationToken);
        var proxyCheckTask = TryGetStringAsync(client, $"https://proxycheck.io/v3/{escaped}", cancellationToken);
        await Task.WhenAll(ipApiTask, proxyCheckTask);

        var items = new List<HealthCheckItem>
        {
            new("数据来源", "ipapi.is / proxycheck.io · 出口 IP 会提交给这两个服务", HealthLevel.Idle)
        };

        JsonDocument? ipApiDocument = null;
        JsonDocument? proxyCheckDocument = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(ipApiTask.Result))
            {
                ipApiDocument = JsonDocument.Parse(ipApiTask.Result);
            }
            if (!string.IsNullOrWhiteSpace(proxyCheckTask.Result))
            {
                proxyCheckDocument = JsonDocument.Parse(proxyCheckTask.Result);
            }

            var ipApi = ipApiDocument?.RootElement;
            JsonElement? proxyResult = null;
            if (proxyCheckDocument is not null &&
                proxyCheckDocument.RootElement.TryGetProperty(address, out var resultElement))
            {
                proxyResult = resultElement;
            }

            var asn = GetDisplay(ipApi, "asn", "asn") ?? GetDisplay(proxyResult, "network", "asn");
            var organisation = GetDisplay(ipApi, "asn", "org")
                ?? GetDisplay(proxyResult, "network", "provider")
                ?? GetDisplay(ipApi, "company", "name");
            if (asn is not null || organisation is not null)
            {
                var normalizedAsn = asn is not null && !asn.StartsWith("AS", StringComparison.OrdinalIgnoreCase)
                    ? $"AS{asn}"
                    : asn;
                items.Add(new HealthCheckItem(
                    "ASN",
                    string.Join(" · ", new[] { normalizedAsn, organisation }.Where(value => !string.IsNullOrWhiteSpace(value))),
                    HealthLevel.Idle));
            }

            var networkType = GetDisplay(ipApi, "asn", "type")
                ?? GetDisplay(ipApi, "company", "type")
                ?? GetDisplay(proxyResult, "network", "type");
            var country = GetDisplay(ipApi, "location", "country");
            var city = GetDisplay(ipApi, "location", "city");
            if (networkType is not null || country is not null || city is not null)
            {
                var location = string.Join(" ", new[] { country, city }.Where(value => !string.IsNullOrWhiteSpace(value)));
                items.Add(new HealthCheckItem(
                    "网络属性",
                    string.Join(" · ", new[] { networkType, location }.Where(value => !string.IsNullOrWhiteSpace(value))),
                    HealthLevel.Idle));
            }

            var risk = GetNumber(proxyResult, "detections", "risk");
            var confidence = GetNumber(proxyResult, "detections", "confidence");
            if (risk is not null)
            {
                var label = risk <= 25 ? "低" : risk <= 50 ? "中" : risk <= 75 ? "高" : "很高";
                var confidenceText = confidence is not null ? $" · 置信度 {confidence:0}%" : string.Empty;
                items.Add(new HealthCheckItem(
                    "proxycheck 风险分",
                    $"{risk:0}/100（{label}）{confidenceText}",
                    risk <= 25 ? HealthLevel.Ok : HealthLevel.Warning));
            }
            else
            {
                items.Add(new HealthCheckItem("proxycheck 风险分", "暂不可用，可能已限流", HealthLevel.Idle));
            }

            var flags = new List<string>();
            AddFlag(flags, GetBoolean(proxyResult, "detections", "hosting"), "数据中心");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "proxy"), "代理出口");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "vpn"), "VPN");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "tor"), "Tor");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "compromised"), "疑似被入侵");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "scraper"), "爬虫");
            AddFlag(flags, GetBoolean(proxyResult, "detections", "anonymous"), "匿名网络");
            AddFlag(flags, GetBoolean(ipApi, "is_abuser"), "滥用记录");
            AddFlag(flags, GetBoolean(ipApi, "is_vpn"), "VPN");
            AddFlag(flags, GetBoolean(ipApi, "is_proxy"), "代理出口");
            AddFlag(flags, GetBoolean(ipApi, "is_tor"), "Tor");
            AddFlag(flags, GetBoolean(ipApi, "is_datacenter"), "数据中心");

            if (flags.Count > 0)
            {
                items.Add(new HealthCheckItem("风险标签", string.Join(" / ", flags.Distinct()), HealthLevel.Warning));
            }
            else if (ipApi is not null || proxyResult is not null)
            {
                items.Add(new HealthCheckItem("风险标签", "未发现代理、VPN、Tor 或滥用标签", HealthLevel.Ok));
            }

            var companyScore = GetDisplay(ipApi, "company", "abuser_score");
            var asnScore = GetDisplay(ipApi, "asn", "abuser_score");
            if (companyScore is not null || asnScore is not null)
            {
                var scores = new List<string>();
                if (companyScore is not null) scores.Add($"组织 {companyScore}");
                if (asnScore is not null) scores.Add($"ASN {asnScore}");
                items.Add(new HealthCheckItem("滥用指标", string.Join(" · ", scores), HealthLevel.Idle));
            }

            if (items.Count == 1)
            {
                items.Add(new HealthCheckItem("风险画像", "第三方服务暂不可用；不影响代理链路检查结果", HealthLevel.Idle));
            }

            items.Add(new HealthCheckItem(
                "结果说明",
                "第三方情报只能作为参考，不能代表目标网站一定放行或封禁",
                HealthLevel.Idle));
            return items;
        }
        catch (JsonException)
        {
            return
            [
                .. items,
                new HealthCheckItem("风险画像", "第三方服务返回了无法解析的数据；不影响链路结果", HealthLevel.Idle)
            ];
        }
        finally
        {
            ipApiDocument?.Dispose();
            proxyCheckDocument?.Dispose();
        }
    }

    private static async Task<string?> TryGetStringAsync(HttpClient client, string url, CancellationToken cancellationToken)
    {
        try
        {
            return await client.GetStringAsync(url, cancellationToken);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or SocketException)
        {
            return null;
        }
    }

    private static string? GetDisplay(JsonElement? root, params string[] path)
    {
        var value = GetElement(root, path);
        if (value is null) return null;
        return value.Value.ValueKind switch
        {
            JsonValueKind.String => value.Value.GetString(),
            JsonValueKind.Number => value.Value.GetRawText(),
            _ => null
        };
    }

    private static double? GetNumber(JsonElement? root, params string[] path)
    {
        var value = GetElement(root, path);
        return value is not null && value.Value.TryGetDouble(out var number) ? number : null;
    }

    private static bool GetBoolean(JsonElement? root, params string[] path)
    {
        var value = GetElement(root, path);
        return value is not null && value.Value.ValueKind == JsonValueKind.True;
    }

    private static JsonElement? GetElement(JsonElement? root, params string[] path)
    {
        if (root is null) return null;
        var current = root.Value;
        foreach (var part in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(part, out var next))
            {
                return null;
            }
            current = next;
        }
        return current;
    }

    private static void AddFlag(ICollection<string> flags, bool present, string label)
    {
        if (present && !flags.Contains(label)) flags.Add(label);
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

    private static async Task<HealthCheckItem> CheckGenerate204Async(HttpClient client, CancellationToken cancellationToken)
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
