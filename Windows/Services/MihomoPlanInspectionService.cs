using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class MihomoPlanInspectionService
{
    private readonly MihomoControllerService _controllerService;

    public MihomoPlanInspectionService(MihomoControllerService controllerService)
    {
        _controllerService = controllerService;
    }

    public async Task<IReadOnlyList<HealthCheckItem>> InspectAsync(
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        using var proxies = await _controllerService.TryGetJsonAsync("/proxies", cancellationToken);
        using var rules = await _controllerService.TryGetJsonAsync("/rules", cancellationToken);
        if (proxies is null || rules is null)
        {
            return
            [
                new HealthCheckItem(
                    "Mihomo 控制接口",
                    "未连接到本地 named pipe；仍会验证额外入口的真实出口",
                    HealthLevel.Warning)
            ];
        }

        var items = new List<HealthCheckItem>();
        var proxyMap = TryGetObject(proxies.RootElement, "proxies");
        if (proxyMap is null || !proxyMap.Value.TryGetProperty(config.SecondaryGroup, out var group))
        {
            items.Add(new HealthCheckItem(
                "额外策略组",
                $"未检测到 {config.SecondaryGroup}",
                HealthLevel.Error));
        }
        else
        {
            var selected = GetString(group, "now");
            var defaultSelected = proxyMap.Value.TryGetProperty(config.DefaultGroup, out var defaultGroup)
                ? GetString(defaultGroup, "now")
                : null;
            if (string.IsNullOrWhiteSpace(selected))
            {
                items.Add(new HealthCheckItem("额外策略组", "没有当前选中出口", HealthLevel.Error));
            }
            else if (string.Equals(selected, "DIRECT", StringComparison.OrdinalIgnoreCase))
            {
                items.Add(new HealthCheckItem("额外策略组", "当前选择 DIRECT，会绕过代理出口", HealthLevel.Error));
            }
            else if (!string.IsNullOrWhiteSpace(defaultSelected) &&
                     string.Equals(selected, defaultSelected, StringComparison.Ordinal))
            {
                items.Add(new HealthCheckItem("额外策略组", "当前与默认策略组复用同一出口", HealthLevel.Error));
            }
            else
            {
                items.Add(new HealthCheckItem("额外策略组", "已选择独立的非 DIRECT 出口", HealthLevel.Ok));
            }

            if (!string.IsNullOrWhiteSpace(selected) &&
                proxyMap.Value.TryGetProperty(selected, out var selectedProxy) &&
                selectedProxy.TryGetProperty("alive", out var alive) &&
                alive.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                items.Add(alive.GetBoolean()
                    ? new HealthCheckItem("出口存活状态", "Mihomo 报告当前出口可用", HealthLevel.Ok)
                    : new HealthCheckItem("出口存活状态", "Mihomo 报告当前出口不可用", HealthLevel.Error));
            }

            if (group.TryGetProperty("all", out var alternatives) &&
                alternatives.ValueKind == JsonValueKind.Array)
            {
                var unsafeCount = alternatives.EnumerateArray().Count(value =>
                {
                    var name = value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                    return string.Equals(name, "DIRECT", StringComparison.OrdinalIgnoreCase) ||
                           !string.IsNullOrWhiteSpace(defaultSelected) &&
                           string.Equals(name, defaultSelected, StringComparison.Ordinal);
                });
                if (unsafeCount > 0)
                {
                    items.Add(new HealthCheckItem(
                        "手动切换风险",
                        $"策略组仍包含 {unsafeCount} 个可能绕过额外出口的选项",
                        HealthLevel.Warning));
                }
            }
        }

        var domains = config.SecondaryDomains
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(value => value.ToLowerInvariant())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var ruleList = rules.RootElement.TryGetProperty("rules", out var ruleArray) &&
                       ruleArray.ValueKind == JsonValueKind.Array
            ? ruleArray.EnumerateArray().ToArray()
            : [];
        if (domains.Length == 0)
        {
            items.Add(new HealthCheckItem("目标域名", "检测方案没有可核对的域名", HealthLevel.Warning));
        }
        else
        {
            var matched = domains.Count(domain => string.Equals(
                FirstPolicyFor(ruleList, domain),
                config.SecondaryGroup,
                StringComparison.Ordinal));
            items.Add(matched == domains.Length
                ? new HealthCheckItem("规则命中", $"{matched} 个目标域名均命中额外策略组", HealthLevel.Ok)
                : new HealthCheckItem(
                    "规则命中",
                    $"仅 {matched}/{domains.Length} 个目标域名命中额外策略组",
                    HealthLevel.Error));
        }

        var delayPath = $"/proxies/{Uri.EscapeDataString(config.SecondaryGroup)}/delay" +
                        $"?url={Uri.EscapeDataString("https://cp.cloudflare.com/generate_204")}&timeout=5000";
        using var delay = await _controllerService.TryGetJsonAsync(delayPath, cancellationToken);
        if (delay is not null &&
            delay.RootElement.TryGetProperty("delay", out var delayValue) &&
            delayValue.TryGetInt32(out var milliseconds) && milliseconds > 0)
        {
            items.Add(new HealthCheckItem("中性延迟", $"{milliseconds} ms", HealthLevel.Ok));
        }
        else
        {
            items.Add(new HealthCheckItem("中性延迟", "Mihomo 没有返回有效延迟", HealthLevel.Error));
        }

        return items;
    }

    private static JsonElement? TryGetObject(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.Object
            ? value
            : null;

    private static string? GetString(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string? FirstPolicyFor(IEnumerable<JsonElement> rules, string domain)
    {
        foreach (var rule in rules)
        {
            var type = GetString(rule, "type")?.Replace("-", string.Empty).ToLowerInvariant();
            var payload = GetString(rule, "payload")?.ToLowerInvariant();
            var matches = type switch
            {
                "domain" => string.Equals(domain, payload, StringComparison.OrdinalIgnoreCase),
                "domainsuffix" => !string.IsNullOrWhiteSpace(payload) &&
                    (string.Equals(domain, payload, StringComparison.OrdinalIgnoreCase) ||
                     domain.EndsWith($".{payload}", StringComparison.OrdinalIgnoreCase)),
                "domainkeyword" => !string.IsNullOrWhiteSpace(payload) &&
                    domain.Contains(payload, StringComparison.OrdinalIgnoreCase),
                _ => false
            };
            if (matches) return GetString(rule, "proxy");
        }

        return null;
    }
}
