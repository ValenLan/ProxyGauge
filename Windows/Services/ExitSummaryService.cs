using System.IO;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public static class ExitSummaryService
{
    private const int MaximumResponseBytes = 64 * 1024;
    private const int MaximumLocationCharacters = 128;
    private const int MaximumCombinedLocationCharacters = 160;
    private static readonly TimeSpan DefaultResolveTimeout = TimeSpan.FromSeconds(15);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private const string SecondarySummaryUrl =
        "https://ipwho.is/?fields=success,ip,country,country_code,region,city";
    private static readonly (string Name, string Url)[] IpServices =
    [
        ("ipify", "https://api.ipify.org"),
        ("ifconfig.me", "https://ifconfig.me/ip"),
        ("ip.sb", "https://ip.sb/ip")
    ];

    public static async Task<ExitSummary> ResolveAsync(
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        var requestTimeout = TimeSpan.FromSeconds(Math.Clamp(config.TimeoutSeconds, 3, 30));
        using var client = CreateSystemRouteClient(requestTimeout);
        return await ResolveWithClientAsync(client, cancellationToken, requestTimeout);
    }

    internal static async Task<ExitSummary> ResolveWithClientAsync(
        HttpClient client,
        CancellationToken cancellationToken = default,
        TimeSpan? requestTimeout = null,
        TimeSpan? totalTimeout = null)
    {
        var deadline = NormalizeRequestTimeout(requestTimeout ?? client.Timeout);
        using var totalDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        totalDeadline.CancelAfter(NormalizeResolveTimeout(totalTimeout ?? DefaultResolveTimeout));
        try
        {
            return await ResolveRequestsAsync(client, deadline, totalDeadline.Token);
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested && totalDeadline.IsCancellationRequested)
        {
            return ExitSummary.Unavailable();
        }
    }

    private static async Task<ExitSummary> ResolveRequestsAsync(
        HttpClient client,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken)
    {
        // Always confirm the primary summary with an independent address service. Starting both
        // together prevents a healthy refresh from consuming two serial request timeouts.
        var primaryTask = TryResolveSummaryAsync(
            client,
            "https://ipapi.co/json/",
            requestTimeout,
            cancellationToken);
        var verifierTask = TryResolvePublicAddressAsync(
            client,
            IpServices[0].Url,
            requestTimeout,
            cancellationToken);

        var primaryCandidate = await primaryTask;
        var verifierAddress = await verifierTask;
        cancellationToken.ThrowIfCancellationRequested();

        if (primaryCandidate is not null)
        {
            if (verifierAddress == primaryCandidate.Summary.Address)
            {
                if (primaryCandidate.HasCountry)
                {
                    return primaryCandidate.Summary;
                }

                var secondary = await TryResolveSummaryAsync(
                    client,
                    SecondarySummaryUrl,
                    requestTimeout,
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (secondary is { HasCountry: true } &&
                    secondary.Summary.Address == primaryCandidate.Summary.Address)
                {
                    return secondary.Summary;
                }
                return new ExitSummary(primaryCandidate.Summary.Address, "国家/地区未知");
            }
        }

        var secondarySummaryTask = TryResolveSummaryAsync(
            client,
            SecondarySummaryUrl,
            requestTimeout,
            cancellationToken);
        // ipify was already queried as the verifier, so do not count the same source twice.
        var addressTasks = IpServices.Skip(1).Select(service =>
            TryResolvePublicAddressAsync(client, service.Url, requestTimeout, cancellationToken)).ToArray();
        var results = await Task.WhenAll(addressTasks);
        var secondaryCandidate = await secondarySummaryTask;
        var candidates = new[] { primaryCandidate, secondaryCandidate }
            .Where(candidate => candidate is not null)
            .Select(candidate => candidate!.Summary.Address)
            .Append(verifierAddress)
            .Concat(results);
        var address = ExitSummary.SelectConsensusAddress(candidates);
        if (address is null)
        {
            return ExitSummary.Unavailable();
        }

        var located = new[] { primaryCandidate, secondaryCandidate }
            .FirstOrDefault(candidate => candidate is { HasCountry: true } &&
                                         candidate.Summary.Address == address);
        return located?.Summary ?? new ExitSummary(address, "国家/地区未知");
    }

    public static ExitSummary? ParseResponse(string? summaryJson, string? fallbackAddress = null) =>
        ParseCandidate(summaryJson, fallbackAddress)?.Summary;

    private static ParsedExitSummary? ParseCandidate(
        string? summaryJson,
        string? fallbackAddress = null)
    {
        var address = ExitSummary.TryNormalizePublicAddress(fallbackAddress, out var normalizedFallback)
            ? normalizedFallback
            : null;
        string? country = null;
        string? region = null;
        string? city = null;

        if (summaryJson is not null && Encoding.UTF8.GetByteCount(summaryJson) > MaximumResponseBytes)
        {
            return address is null
                ? null
                : new ParsedExitSummary(new ExitSummary(address, "国家/地区未知"), false);
        }

        if (!string.IsNullOrWhiteSpace(summaryJson))
        {
            try
            {
                using var document = JsonDocument.Parse(summaryJson);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object)
                {
                    return address is null
                        ? null
                        : new ParsedExitSummary(new ExitSummary(address, "国家/地区未知"), false);
                }

                if (IsErrorResponse(root))
                {
                    return address is null
                        ? null
                        : new ParsedExitSummary(new ExitSummary(address, "国家/地区未知"), false);
                }

                var responseAddress = ReadString(root, "ip");
                if (ExitSummary.TryNormalizePublicAddress(responseAddress, out var normalizedResponse))
                {
                    address = normalizedResponse;
                    country = FirstNonBlank(
                        ReadLocationString(root, "country_name"),
                        ReadNestedLocationString(root, "location", "country"),
                        ReadLocationString(root, "country"),
                        ReadLocationString(root, "country_code"),
                        ReadLocationString(root, "cc"));
                    region = FirstNonBlank(
                        ReadLocationString(root, "region"),
                        ReadLocationString(root, "region_name"),
                        ReadNestedLocationString(root, "location", "region"));
                    city = FirstNonBlank(
                        ReadLocationString(root, "city"),
                        ReadNestedLocationString(root, "location", "city"));
                }
            }
            catch (Exception exception) when (exception is JsonException or InvalidOperationException)
            {
                // The validated fallback address remains usable without location metadata.
            }
        }

        if (address is null)
        {
            return null;
        }

        IEnumerable<string> locationParts = country is null
            ? new[] { "国家/地区未知" }
            : new[] { country, region, city }
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase);
        return new ParsedExitSummary(
            new ExitSummary(address, BoundCombinedLocation(string.Join(" · ", locationParts))),
            country is not null);
    }

    internal static async Task<string> GetNoCacheStringAsync(
        HttpClient client,
        string url,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(NormalizeRequestTimeout(requestTimeout));
        var requestCancellation = deadline.Token;
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.CacheControl = new CacheControlHeaderValue
        {
            NoCache = true,
            NoStore = true,
            MaxAge = TimeSpan.Zero
        };
        request.Headers.Pragma.ParseAdd("no-cache");

        using var response = await client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            requestCancellation);
        if (!Equals(response.RequestMessage?.RequestUri, request.RequestUri))
        {
            throw new HttpRequestException("IP 查询响应来自非预期地址。");
        }
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > MaximumResponseBytes)
        {
            throw new HttpRequestException("IP 查询响应超出安全大小限制。");
        }

        await using var input = await response.Content.ReadAsStreamAsync(requestCancellation);
        using var output = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var read = await input.ReadAsync(buffer, requestCancellation);
            if (read == 0)
            {
                break;
            }
            if (output.Length + read > MaximumResponseBytes)
            {
                throw new HttpRequestException("IP 查询响应超出安全大小限制。");
            }
            output.Write(buffer, 0, read);
        }

        return StrictUtf8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
    }

    private static HttpClient CreateSystemRouteClient(TimeSpan requestTimeout)
    {
        var handler = new SocketsHttpHandler
        {
            Proxy = HttpClient.DefaultProxy,
            UseProxy = true,
            AllowAutoRedirect = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = requestTimeout,
            PooledConnectionLifetime = TimeSpan.FromSeconds(30)
        };
        return new HttpClient(handler)
        {
            Timeout = requestTimeout
        };
    }

    private static async Task<string?> TryResolvePublicAddressAsync(
        HttpClient client,
        string url,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken)
    {
        try
        {
            var value = (await GetNoCacheStringAsync(
                client,
                url,
                requestTimeout,
                cancellationToken)).Trim();
            return ExitSummary.TryNormalizePublicAddress(value, out var normalized)
                ? normalized
                : null;
        }
        catch (Exception exception) when (
            !cancellationToken.IsCancellationRequested &&
            exception is HttpRequestException or OperationCanceledException or IOException or DecoderFallbackException)
        {
            return null;
        }
    }

    private static async Task<ParsedExitSummary?> TryResolveSummaryAsync(
        HttpClient client,
        string url,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken)
    {
        try
        {
            var value = await GetNoCacheStringAsync(
                client,
                url,
                requestTimeout,
                cancellationToken);
            return ParseCandidate(value);
        }
        catch (Exception exception) when (
            !cancellationToken.IsCancellationRequested &&
            exception is HttpRequestException or OperationCanceledException or IOException or
                JsonException or InvalidOperationException or DecoderFallbackException)
        {
            return null;
        }
    }

    private static TimeSpan NormalizeRequestTimeout(TimeSpan value)
    {
        if (value == Timeout.InfiniteTimeSpan || value <= TimeSpan.Zero)
        {
            return TimeSpan.FromSeconds(30);
        }
        return value > TimeSpan.FromSeconds(30)
            ? TimeSpan.FromSeconds(30)
            : value;
    }

    private static TimeSpan NormalizeResolveTimeout(TimeSpan value)
    {
        if (value == Timeout.InfiniteTimeSpan || value <= TimeSpan.Zero)
        {
            return DefaultResolveTimeout;
        }
        return value > DefaultResolveTimeout ? DefaultResolveTimeout : value;
    }

    private static string? ReadString(JsonElement element, string property)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(property, out var value)) return null;
        var text = value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    }

    private static string? ReadNestedString(JsonElement element, string container, string property) =>
        element.TryGetProperty(container, out var nested) && nested.ValueKind == JsonValueKind.Object
            ? ReadString(nested, property)
            : null;

    private static string? ReadLocationString(JsonElement element, string property) =>
        NormalizeLocationText(ReadString(element, property));

    private static string? ReadNestedLocationString(
        JsonElement element,
        string container,
        string property) =>
        NormalizeLocationText(ReadNestedString(element, container, property));

    private static string? NormalizeLocationText(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (value.Any(character =>
                char.GetUnicodeCategory(character) == UnicodeCategory.Format ||
                char.GetUnicodeCategory(character) == UnicodeCategory.Control &&
                !char.IsWhiteSpace(character)))
        {
            return null;
        }

        var normalized = string.Join(
            " ",
            value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return normalized.Length is > 0 and <= MaximumLocationCharacters
            ? normalized
            : null;
    }

    private static string? FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();

    private static string BoundCombinedLocation(string value)
    {
        var elementStarts = StringInfo.ParseCombiningCharacters(value);
        return elementStarts.Length <= MaximumCombinedLocationCharacters
            ? value
            : value[..elementStarts[MaximumCombinedLocationCharacters - 1]] + "…";
    }

    private static bool IsErrorResponse(JsonElement root)
    {
        if (root.TryGetProperty("success", out var success))
        {
            if (success.ValueKind != JsonValueKind.True)
            {
                return true;
            }
        }
        if (!root.TryGetProperty("error", out var value))
        {
            return false;
        }

        return value.ValueKind switch
        {
            JsonValueKind.False or JsonValueKind.Null => false,
            JsonValueKind.True => true,
            JsonValueKind.String => value.GetString()?.Trim().ToLowerInvariant() switch
            {
                null or "" or "false" or "0" or "no" => false,
                _ => true
            },
            JsonValueKind.Number => !value.TryGetDouble(out var number) || number != 0,
            _ => true
        };
    }

    private sealed record ParsedExitSummary(ExitSummary Summary, bool HasCountry);
}
