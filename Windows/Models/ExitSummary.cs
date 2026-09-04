using System.Net;
using System.Net.Sockets;

namespace ProxyGauge.Models;

public enum ExitSummaryState { Available, Checking, Disconnected, Unavailable }

public sealed record ExitSummary(
    string Address,
    string Location)
{
    public ExitSummaryState State { get; init; } = ExitSummaryState.Available;
    public string? IpVersion => ParseIpVersion(Address);
    public bool HasIpVersion => IpVersion is not null;

    public static bool IsSupportedAddress(string? address) =>
        TryNormalizePublicAddress(address, out _);

    public static bool TryNormalizePublicAddress(string? address, out string normalized)
    {
        normalized = string.Empty;
        if (ParseIpVersion(address) is null ||
            !IPAddress.TryParse(address, out var parsed))
        {
            return false;
        }

        if (parsed.IsIPv4MappedToIPv6)
        {
            parsed = parsed.MapToIPv4();
        }

        if (!IsPublicAddress(parsed))
        {
            return false;
        }

        normalized = parsed.ToString();
        return true;
    }

    public static bool AreEquivalentPublicAddresses(string? first, string? second) =>
        TryNormalizePublicAddress(first, out var normalizedFirst) &&
        TryNormalizePublicAddress(second, out var normalizedSecond) &&
        string.Equals(normalizedFirst, normalizedSecond, StringComparison.Ordinal);

    public static string? SelectConsensusAddress(IEnumerable<string?> addresses)
    {
        var normalizedAddresses = addresses
            .Select(address => TryNormalizePublicAddress(address, out var normalized)
                ? normalized
                : null)
            .Where(address => address is not null)
            .Cast<string>()
            .ToArray();
        var groups = normalizedAddresses
            .GroupBy(address => address, StringComparer.Ordinal)
            .OrderByDescending(group => group.Count())
            .ThenBy(group => group.Key, StringComparer.Ordinal)
            .ToArray();

        if (groups.Length == 0)
        {
            return null;
        }

        return groups[0].Count() >= 2 &&
               groups[0].Count() * 2 > normalizedAddresses.Length
            ? groups[0].Key
            : null;
    }

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

    private static bool IsPublicAddress(IPAddress address)
    {
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var bytes = address.GetAddressBytes();
            return bytes[0] is > 0 and < 224 &&
                   bytes[0] != 10 &&
                   bytes[0] != 127 &&
                   !(bytes[0] == 100 && bytes[1] is >= 64 and <= 127) &&
                   !(bytes[0] == 169 && bytes[1] == 254) &&
                   !(bytes[0] == 172 && bytes[1] is >= 16 and <= 31) &&
                   !(bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0) &&
                   !(bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2) &&
                   !(bytes[0] == 192 && bytes[1] == 31 && bytes[2] == 196) &&
                   !(bytes[0] == 192 && bytes[1] == 52 && bytes[2] == 193) &&
                   !(bytes[0] == 192 && bytes[1] == 88 && bytes[2] == 99) &&
                   !(bytes[0] == 192 && bytes[1] == 168) &&
                   !(bytes[0] == 192 && bytes[1] == 175 && bytes[2] == 48) &&
                   !(bytes[0] == 198 && bytes[1] is 18 or 19) &&
                   !(bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) &&
                   !(bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113);
        }

        if (address.AddressFamily != AddressFamily.InterNetworkV6 ||
            address.Equals(IPAddress.IPv6Any) ||
            address.Equals(IPAddress.IPv6Loopback) ||
            address.IsIPv6LinkLocal ||
            address.IsIPv6Multicast ||
            address.IsIPv6SiteLocal)
        {
            return false;
        }

        var ipv6 = address.GetAddressBytes();
        if ((ipv6[0] & 0xFE) == 0xFC)
        {
            return false;
        }
        var isGlobalUnicast = (ipv6[0] & 0xE0) == 0x20;
        var isIetfProtocolAssignment = ipv6[0] == 0x20 && ipv6[1] == 0x01 && ipv6[2] < 0x02;
        var isDocumentation = ipv6[0] == 0x20 && ipv6[1] == 0x01 &&
                              ipv6[2] == 0x0D && ipv6[3] == 0xB8;
        var isSixToFour = ipv6[0] == 0x20 && ipv6[1] == 0x02;
        var isAs112 = ipv6[0] == 0x26 && ipv6[1] == 0x20 &&
                      ipv6[2] == 0x00 && ipv6[3] == 0x4F &&
                      ipv6[4] == 0x80 && ipv6[5] == 0x00;
        var isAdditionalDocumentation = ipv6[0] == 0x3F && ipv6[1] == 0xFF &&
                                        (ipv6[2] & 0xF0) == 0;
        return isGlobalUnicast && !isIetfProtocolAssignment && !isDocumentation &&
               !isSixToFour && !isAs112 && !isAdditionalDocumentation;
    }

    public static ExitSummary Unavailable() =>
        new("暂时无法读取", "出口查询未能确认，稍后重试") { State = ExitSummaryState.Unavailable };

    public static ExitSummary Disconnected() =>
        new("已断开网络连接", "当前互联网路径不可用；局域网可能仍可用") { State = ExitSummaryState.Disconnected };

    public static ExitSummary Waiting() =>
        new("等待重新检测", "网络路径已变化，旧出口已清除") { State = ExitSummaryState.Unavailable };

    public static ExitSummary WaitingForPathChange() =>
        new("等待出口变化", "路由、系统代理或 VPN 变化后自动检测") { State = ExitSummaryState.Unavailable };

    public static ExitSummary Checking() =>
        new("正在检测", "正在确认系统实际出口") { State = ExitSummaryState.Checking };
}
