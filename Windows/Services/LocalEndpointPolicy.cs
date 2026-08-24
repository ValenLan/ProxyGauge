using System.Net;

namespace ProxyGauge.Services;

public static class LocalEndpointPolicy
{
    public const string DefaultHost = "127.0.0.1";

    public static bool IsLoopbackHost(string? host)
    {
        if (string.IsNullOrWhiteSpace(host)) return false;

        var value = host.Trim();
        return string.Equals(value, "localhost", StringComparison.OrdinalIgnoreCase) ||
               IPAddress.TryParse(value.Trim('[', ']'), out var address) &&
               IPAddress.IsLoopback(address);
    }

    public static string NormalizeLoopbackHost(string? host)
    {
        if (!IsLoopbackHost(host)) return DefaultHost;

        var value = host!.Trim();
        return string.Equals(value, "localhost", StringComparison.OrdinalIgnoreCase)
            ? DefaultHost
            : value.Trim('[', ']');
    }
}
