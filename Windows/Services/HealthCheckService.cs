using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;
using CloudRoute.Models;

namespace CloudRoute.Services;

public sealed class HealthCheckService
{
    private static readonly (string Name, string Url)[] IpServices =
    [
        ("ipify", "https://api.ipify.org"),
        ("ifconfig.me", "https://ifconfig.me/ip"),
        ("ip.sb", "https://ip.sb/ip")
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
        if (snapshot.TunDetected)
        {
            localItems.Add(await CheckFakeIpDnsAsync(cancellationToken));
        }

        using var handler = new SocketsHttpHandler
        {
            Proxy = new WebProxy(new Uri($"http://{config.MixedHost}:{config.MixedPort}")),
            UseProxy = true,
            ConnectTimeout = TimeSpan.FromSeconds(config.TimeoutSeconds)
        };
        using var client = new HttpClient(handler)
        {
            // PeeringDB metadata can take slightly longer than ordinary reachability
            // probes. Match the macOS metadata budget without changing connect timeout.
            Timeout = TimeSpan.FromSeconds(Math.Max(config.TimeoutSeconds, 12))
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("CloudRoute/1.3.8 (+https://github.com/ValenLan/CloudRoute)");

        var exitResult = await CheckExitIpAsync(client, config, cancellationToken);
        var riskTask = CheckIpRiskAsync(client, exitResult.Address, cancellationToken);

        var riskItems = await riskTask;

        return new HealthReport
        {
            CheckedAt = DateTime.Now,
            Sections =
            [
                new HealthCheckSection("本地代理", localItems, 45, IsCritical: true),
                new HealthCheckSection("代理出口", [exitResult.Item], 30, IsCritical: true),
                new HealthCheckSection("IP 风险画像", riskItems, 15),
                new HealthCheckSection("AI 路由确认（默认低风险模式）",
                [
                    new HealthCheckItem(
                        "主动平台探测",
                        "已关闭 · 不请求 Claude、ChatGPT 或 Gemini 网页与 API",
                        HealthLevel.Ok)
                ], 10)
            ]
        };
    }

    private static async Task<(HealthCheckItem Item, string? Address)> CheckExitIpAsync(
        HttpClient client,
        AppConfig config,
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
        var expected = config.ExpectedIp.Trim();
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
        return (new HealthCheckItem("出口一致性", $"{verdict} · {sourceSummary}", level), address);
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
            new("数据来源", "ipapi.is / proxycheck.io / PeeringDB · 前两者查询 IP，PeeringDB 查询 ASN", HealthLevel.Idle)
        };

        JsonDocument? ipApiDocument = null;
        JsonDocument? proxyCheckDocument = null;
        JsonDocument? peeringDbDocument = null;
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

            var asn = GetDisplay(ipApi, "asn", "asn")
                ?? GetDisplay(ipApi, "asn_num")
                ?? GetDisplay(proxyResult, "network", "asn");
            var organisation = GetDisplay(ipApi, "asn", "org")
                ?? GetDisplay(ipApi, "asn_org")
                ?? GetDisplay(proxyResult, "network", "provider")
                ?? GetDisplay(ipApi, "company", "name")
                ?? GetDisplay(ipApi, "company_name");
            if (asn is not null || organisation is not null)
            {
                var normalizedAsn = asn is not null && !asn.StartsWith("AS", StringComparison.OrdinalIgnoreCase)
                    ? $"AS{asn}"
                    : asn;
                items.Add(new HealthCheckItem(
                    "网络归属",
                    string.Join(" · ", new[] { normalizedAsn, organisation }.Where(value => !string.IsNullOrWhiteSpace(value))),
                    HealthLevel.Idle));
            }

            var asnNumber = asn?.Trim();
            if (asnNumber?.StartsWith("AS", StringComparison.OrdinalIgnoreCase) == true)
            {
                asnNumber = asnNumber[2..];
            }
            if (long.TryParse(asnNumber, out var numericAsn))
            {
                var peeringJson = await TryGetStringAsync(
                    client,
                    $"https://www.peeringdb.com/api/net?asn={numericAsn}",
                    cancellationToken);
                if (!string.IsNullOrWhiteSpace(peeringJson))
                {
                    peeringDbDocument = JsonDocument.Parse(peeringJson);
                }
            }

            var peeringRecord = GetFirstArrayItem(peeringDbDocument?.RootElement, "data");
            var peeringType = GetFirstString(peeringRecord, "info_types")
                ?? GetDisplay(peeringRecord, "info_type");
            var asnType = peeringType ?? GetDisplay(ipApi, "asn", "type");
            if (asnType is not null)
            {
                items.Add(new HealthCheckItem(
                    "ASN 属性",
                    $"{NetworkTypeLabel(asnType)}（{(peeringType is not null ? "PeeringDB" : "ipapi.is")}）",
                    HealthLevel.Idle));
            }

            var proxyType = GetDisplay(proxyResult, "network", "type");
            var allocationType = proxyType ?? GetDisplay(ipApi, "company", "type");
            if (allocationType is not null)
            {
                items.Add(new HealthCheckItem(
                    "IP 段用途",
                    $"{NetworkTypeLabel(allocationType)}（{(proxyType is not null ? "proxycheck.io" : "ipapi.is")}）",
                    HealthLevel.Idle));
            }

            var country = GetDisplay(ipApi, "location", "country") ?? GetDisplay(ipApi, "cc");
            var city = GetDisplay(ipApi, "location", "city");
            if (country is not null || city is not null)
            {
                var location = string.Join(" ", new[] { country, city }.Where(value => !string.IsNullOrWhiteSpace(value)));
                items.Add(new HealthCheckItem("地区", location, HealthLevel.Idle));
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
                items.Add(new HealthCheckItem("地址风险标签", string.Join(" / ", flags.Distinct()), HealthLevel.Warning));
            }
            else if (ipApi is not null || proxyResult is not null)
            {
                items.Add(new HealthCheckItem("地址风险标签", "未发现代理、VPN、Tor 或滥用记录", HealthLevel.Ok));
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
                "第三方 IP 情报仅供参考，不代表浏览器环境或具体服务可用性",
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
            peeringDbDocument?.Dispose();
        }
    }

    private static string NetworkTypeLabel(string value) => value.Trim().ToLowerInvariant() switch
    {
        "nsp" => "ISP / 网络服务商",
        "cable/dsl/isp" => "ISP / 宽带运营商",
        "isp" => "ISP / 网络服务商",
        "business" => "商业网络",
        "enterprise" => "企业网络",
        "hosting" => "托管 / 数据中心",
        "residential" => "住宅宽带",
        "wireless" => "移动 / 无线网络",
        "educational/research" => "教育 / 研究网络",
        "government" => "政府网络",
        "content" => "内容网络",
        _ => value
    };

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

    private static JsonElement? GetFirstArrayItem(JsonElement? root, params string[] path)
    {
        var value = GetElement(root, path);
        return value is not null &&
               value.Value.ValueKind == JsonValueKind.Array &&
               value.Value.GetArrayLength() > 0
            ? value.Value[0]
            : null;
    }

    private static string? GetFirstString(JsonElement? root, params string[] path)
    {
        var value = GetElement(root, path);
        if (value is null || value.Value.ValueKind != JsonValueKind.Array) return null;
        foreach (var item in value.Value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(item.GetString()))
            {
                return item.GetString();
            }
        }
        return null;
    }

    private static void AddFlag(ICollection<string> flags, bool present, string label)
    {
        if (present && !flags.Contains(label)) flags.Add(label);
    }

}
