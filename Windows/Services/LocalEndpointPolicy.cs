using System.Net;
using System.Net.Sockets;

namespace ProxyGauge.Services;

public static class LocalEndpointPolicy
{
    public const string DefaultHost = "127.0.0.1";

    public static bool IsLoopbackHost(string? host)
    {
        return TryNormalizeLoopbackHost(host, out _);
    }

    public static string NormalizeLoopbackHost(string? host)
    {
        return TryNormalizeLoopbackHost(host, out var normalized) ? normalized : DefaultHost;
    }

    public static string FormatEndpoint(string? host, int port)
    {
        var value = (host ?? string.Empty).Trim().Trim('[', ']');
        if (IPAddress.TryParse(value, out var address) &&
            address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return $"[{address}]:{port}";
        }
        return $"{value}:{port}";
    }

    private static bool TryNormalizeLoopbackHost(string? host, out string normalized)
    {
        normalized = DefaultHost;
        if (string.IsNullOrWhiteSpace(host)) return false;

        var value = host.Trim();
        if (string.Equals(value, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        value = value.Trim('[', ']');
        if (value.Contains('%') || !IPAddress.TryParse(value, out var address))
        {
            return false;
        }

        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var parts = value.Split('.');
            if (parts.Length != 4 || parts.Any(part =>
                    !byte.TryParse(part, out var octet) ||
                    !string.Equals(part, octet.ToString(), StringComparison.Ordinal)))
            {
                return false;
            }
            if (address.GetAddressBytes()[0] != 127)
            {
                return false;
            }
            normalized = address.ToString();
            return true;
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6 &&
            address.Equals(IPAddress.IPv6Loopback))
        {
            normalized = IPAddress.IPv6Loopback.ToString();
            return true;
        }
        return false;
    }
}
