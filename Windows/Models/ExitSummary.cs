using System.Net;
using System.Net.Sockets;

namespace ProxyGauge.Models;

public sealed record ExitSummary(
    string Address,
    string Location)
{
    public string? IpVersion => ParseIpVersion(Address);
    public bool HasIpVersion => IpVersion is not null;

    public static bool IsSupportedAddress(string? address) => ParseIpVersion(address) is not null;

    private static string? ParseIpVersion(string? address)
    {
        if (string.IsNullOrEmpty(address) ||
            !string.Equals(address, address.Trim(), StringComparison.Ordinal) ||
            address.Contains('\0') || address.Contains('%'))
        {
            return null;
        }

        if (IsStrictIpv4(address))
        {
            return "IPv4";
        }

        if (!address.Contains(':') || address.StartsWith('[') || address.EndsWith(']'))
        {
            return null;
        }
        if (address.Contains('.'))
        {
            var separator = address.LastIndexOf(':');
            if (separator < 0 || !IsStrictIpv4(address[(separator + 1)..]))
            {
                return null;
            }
        }

        return IPAddress.TryParse(address, out var parsed) &&
               parsed.AddressFamily == AddressFamily.InterNetworkV6
            ? "IPv6"
            : null;
    }

    private static bool IsStrictIpv4(string address)
    {
        var octets = address.Split('.');
        return octets.Length == 4 && octets.All(octet =>
            octet.Length is >= 1 and <= 3 &&
            octet.All(character => character is >= '0' and <= '9') &&
            (octet.Length == 1 || octet[0] != '0') &&
            byte.TryParse(octet, out _));
    }

    public static ExitSummary Unavailable() =>
        new("暂时无法读取", "请检查本地代理连接");
}
