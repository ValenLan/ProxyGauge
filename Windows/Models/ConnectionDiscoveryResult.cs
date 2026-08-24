namespace ProxyGauge.Models;

public sealed record ConnectionDiscoveryResult(
    bool Found,
    string Host,
    int Port,
    string ClientName,
    string Source,
    bool SystemProxyEnabled,
    bool TunDetected)
{
    public string Endpoint => $"{Host}:{Port}";
    public string TrafficMode => SystemProxyEnabled && TunDetected
        ? "系统代理与 TUN"
        : TunDetected ? "TUN" : SystemProxyEnabled ? "系统代理" : "未检测到流量入口";
}
