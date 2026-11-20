namespace ProxyGauge.Models;

public sealed record ExitSummary(
    string Address,
    string Location,
    string Network,
    string NetworkType)
{
    public static ExitSummary Unavailable() =>
        new("暂时无法读取", "请检查本地代理连接", "ASN 未知", "网络类型未知");
}
