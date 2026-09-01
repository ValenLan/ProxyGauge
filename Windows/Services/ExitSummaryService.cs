using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public static class ExitSummaryService
{
    public static async Task<ExitSummary> ResolveAsync(
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        using var client = CreateProxyClient(config);
        try
        {
            var summaryJson = await client.GetStringAsync("https://ipapi.co/json/", cancellationToken);
            var summary = ParseResponse(summaryJson);
            if (summary is not null)
            {
                return summary;
            }
        }
        catch (Exception exception) when (
            exception is HttpRequestException or TaskCanceledException or SocketException or JsonException)
        {
            // Fall back to the existing proxy-routed IP-only sources below.
        }

        var address = await HealthCheckService.ResolveDefaultExitIpAsync(config, cancellationToken);
        return address is null
            ? ExitSummary.Unavailable()
            : new ExitSummary(address, "位置未知");
    }

    public static ExitSummary? ParseResponse(string? summaryJson, string? fallbackAddress = null)
    {
        var address = IPAddress.TryParse(fallbackAddress, out _) ? fallbackAddress : null;
        string? country = null;
        string? cityOrRegion = null;

        if (!string.IsNullOrWhiteSpace(summaryJson))
        {
            try
            {
                using var document = JsonDocument.Parse(summaryJson);
                var root = document.RootElement;
                var responseAddress = ReadString(root, "ip");
                if (IPAddress.TryParse(responseAddress, out _))
                {
                    address = responseAddress;
                    country = ReadString(root, "country_name")
                        ?? ReadNestedString(root, "location", "country")
                        ?? ReadString(root, "country")
                        ?? ReadString(root, "cc");
                    cityOrRegion = ReadString(root, "city")
                        ?? ReadNestedString(root, "location", "city")
                        ?? ReadString(root, "region")
                        ?? ReadNestedString(root, "location", "region");
                }
            }
            catch (JsonException)
            {
                // The validated fallback address remains usable without location metadata.
            }
        }

        if (address is null)
        {
            return null;
        }

        var location = string.Join(" · ", new[] { country, cityOrRegion }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        return new ExitSummary(
            address,
            string.IsNullOrWhiteSpace(location) ? "位置未知" : location);
    }

    private static HttpClient CreateProxyClient(AppConfig config)
    {
        if (!LocalEndpointPolicy.IsLoopbackHost(config.MixedHost) || config.MixedPort is < 1 or > 65535)
        {
            throw new InvalidOperationException("ProxyGauge 只允许通过本机回环代理读取出口信息。");
        }
        var handler = new SocketsHttpHandler
        {
            Proxy = new WebProxy(new UriBuilder(
                Uri.UriSchemeHttp,
                config.MixedHost.Trim('[', ']'),
                config.MixedPort).Uri),
            UseProxy = true,
            ConnectTimeout = TimeSpan.FromSeconds(config.TimeoutSeconds)
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(config.TimeoutSeconds) };
    }

    private static string? ReadString(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            _ => null
        };
    }

    private static string? ReadNestedString(JsonElement element, string container, string property) =>
        element.TryGetProperty(container, out var nested) && nested.ValueKind == JsonValueKind.Object
            ? ReadString(nested, property)
            : null;
}
