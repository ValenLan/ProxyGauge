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
        string? primaryJson = null;
        try
        {
            primaryJson = await client.GetStringAsync("https://api.ipapi.is", cancellationToken);
        }
        catch (Exception exception) when (
            exception is HttpRequestException or TaskCanceledException or SocketException or JsonException)
        {
            // The independent proxy-routed IP sources below keep the card useful.
        }

        var address = ReadAddress(primaryJson)
            ?? await HealthCheckService.ResolveDefaultExitIpAsync(config, cancellationToken);
        if (address is null)
        {
            return ExitSummary.Unavailable();
        }

        if (!HasDetailedMetadata(primaryJson) || !HasNetworkClassification(primaryJson))
        {
            try
            {
                var detailJson = await client.GetStringAsync(
                    $"https://api.ipapi.is/?q={Uri.EscapeDataString(address)}",
                    cancellationToken);
                if (ResponseMatchesAddress(detailJson, address))
                {
                    primaryJson = detailJson;
                }
            }
            catch (Exception exception) when (
                exception is HttpRequestException or TaskCanceledException or SocketException or JsonException)
            {
                // Keep the verified compact response; an absent classification stays unknown.
            }
        }

        string? geoJson = null;
        if (!HasDetailedMetadata(primaryJson))
        {
            try
            {
                geoJson = await client.GetStringAsync(
                    $"https://ipapi.co/{Uri.EscapeDataString(address)}/json/",
                    cancellationToken);
            }
            catch (Exception exception) when (
                exception is HttpRequestException or TaskCanceledException or SocketException or JsonException)
            {
                // The flat ipapi.is response still supplies ASN and network flags.
            }
        }

        return ParseResponse(primaryJson, geoJson, address)
            ?? new ExitSummary(address, "位置未知", "ASN 未知", "IP 类型未知");
    }

    public static ExitSummary? ParseResponse(
        string? primaryJson,
        string? geoJson = null,
        string? fallbackAddress = null)
    {
        var address = IPAddress.TryParse(fallbackAddress, out _) ? fallbackAddress : null;
        string? country = null;
        string? city = null;
        string? asn = null;
        string? organization = null;
        string? rawType = null;
        bool? isDatacenter = null;
        bool? isVpn = null;
        bool? isProxy = null;
        bool? isTor = null;
        bool? isMobile = null;
        bool? isSatellite = null;

        if (!string.IsNullOrWhiteSpace(primaryJson))
        {
            try
            {
                using var document = JsonDocument.Parse(primaryJson);
                var root = document.RootElement;
                var responseAddress = ReadString(root, "ip");
                if (IPAddress.TryParse(responseAddress, out _))
                {
                    address = responseAddress;
                }
                country = ReadNestedString(root, "location", "country")
                    ?? ReadString(root, "country_name")
                    ?? ReadString(root, "cc");
                city = ReadNestedString(root, "location", "city")
                    ?? ReadString(root, "city");
                asn = ReadNestedString(root, "asn", "asn")
                    ?? ReadString(root, "asn_num");
                organization = ReadNestedString(root, "asn", "org")
                    ?? ReadString(root, "asn_org")
                    ?? ReadString(root, "company_name");
                rawType = ReadNestedString(root, "company", "type")
                    ?? ReadNestedString(root, "asn", "type");
                isDatacenter = ReadBoolean(root, "is_datacenter");
                isVpn = ReadBoolean(root, "is_vpn");
                isProxy = ReadBoolean(root, "is_proxy");
                isTor = ReadBoolean(root, "is_tor");
                isMobile = ReadBoolean(root, "is_mobile");
                isSatellite = ReadBoolean(root, "is_satellite");
            }
            catch (JsonException)
            {
                // The fallback address and secondary location payload remain usable.
            }
        }

        if (address is null)
        {
            return null;
        }

        if (!string.IsNullOrWhiteSpace(geoJson))
        {
            try
            {
                using var document = JsonDocument.Parse(geoJson);
                var root = document.RootElement;
                var geoAddress = ReadString(root, "ip");
                if (string.Equals(geoAddress, address, StringComparison.OrdinalIgnoreCase))
                {
                    var fullCountry = ReadString(root, "country_name")
                        ?? ReadString(root, "country");
                    if (!string.IsNullOrWhiteSpace(fullCountry)) country = fullCountry;
                    city ??= ReadString(root, "city");
                    asn ??= ReadString(root, "asn");
                    organization ??= ReadString(root, "org");
                }
            }
            catch (JsonException)
            {
                // Ignore malformed enrichment without discarding the verified IP.
            }
        }

        if (!string.IsNullOrWhiteSpace(asn) && !asn.StartsWith("AS", StringComparison.OrdinalIgnoreCase))
        {
            asn = $"AS{asn}";
        }
        var location = string.Join(" · ", new[] { country, city }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        var network = string.Join(" · ", new[] { asn, organization }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        return new ExitSummary(
            address,
            string.IsNullOrWhiteSpace(location) ? "位置未知" : location,
            string.IsNullOrWhiteSpace(network) ? "ASN 未知" : network,
            NetworkTypeLabel(
                rawType,
                isDatacenter,
                isVpn,
                isProxy,
                isTor,
                isMobile,
                isSatellite));
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

    private static bool? ReadBoolean(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) &&
        value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    private static string? ReadAddress(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var value = ReadString(document.RootElement, "ip");
            return IPAddress.TryParse(value, out _) ? value : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool HasDetailedMetadata(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            return !string.IsNullOrWhiteSpace(ReadNestedString(root, "location", "country"))
                && !string.IsNullOrWhiteSpace(ReadNestedString(root, "location", "city"))
                && !string.IsNullOrWhiteSpace(ReadNestedString(root, "asn", "asn"))
                && !string.IsNullOrWhiteSpace(ReadNestedString(root, "asn", "org"));
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool HasNetworkClassification(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            return !string.IsNullOrWhiteSpace(ReadNestedString(root, "company", "type"))
                || !string.IsNullOrWhiteSpace(ReadNestedString(root, "asn", "type"));
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool ResponseMatchesAddress(string? json, string address)
    {
        var responseAddress = ReadAddress(json);
        return IPAddress.TryParse(responseAddress, out var parsedResponse)
            && IPAddress.TryParse(address, out var parsedExpected)
            && parsedResponse.Equals(parsedExpected);
    }

    private static string NetworkTypeLabel(
        string? value,
        bool? isDatacenter,
        bool? isVpn,
        bool? isProxy,
        bool? isTor,
        bool? isMobile,
        bool? isSatellite) => value?.ToLowerInvariant() switch
    {
        _ when isTor == true => "Tor 出口",
        _ when isVpn == true => "VPN 出口",
        _ when isProxy == true => "代理出口",
        _ when isDatacenter == true => "数据中心",
        _ when isMobile == true => "移动网络",
        _ when isSatellite == true => "卫星网络",
        "isp" => "ISP 网络",
        "hosting" => "数据中心",
        "education" => "教育网络",
        "government" => "政府网络",
        "banking" => "金融网络",
        "business" => "商业网络",
        _ => "IP 类型未知"
    };
}
