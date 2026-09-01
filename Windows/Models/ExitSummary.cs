namespace ProxyGauge.Models;

public sealed record ExitSummary(
    string Address,
    string Location)
{
    public static ExitSummary Unavailable() =>
        new("暂时无法读取", "请检查本地代理连接");
}
