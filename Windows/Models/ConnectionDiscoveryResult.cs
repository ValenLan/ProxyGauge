namespace ProxyGauge.Models;

public sealed record ConnectionDiscoveryResult(
    bool Found,
    string Host,
    int Port,
    string ClientName,
    string Source,
    bool SystemProxyEnabled,
    bool TunDetected,
    bool OtherTunnelDetected,
    bool SplitTunnelDetected = false,
    bool VirtualNetworkDetected = false,
    bool RouteLookupUnknown = false,
    bool EndpointOwnershipChecked = false,
    bool EndpointOwnedByMihomo = false)
{
    public string Endpoint => ProxyGauge.Services.LocalEndpointPolicy.FormatEndpoint(Host, Port);
    public string TrafficMode
    {
        get
        {
            if (RouteLookupUnknown)
            {
                return SystemProxyEnabled ? "系统代理；路由状态无法确认" : "路由状态无法确认";
            }
            if (SplitTunnelDetected)
            {
                return SystemProxyEnabled
                    ? "系统代理与路由分流"
                    : "路由分流（可能直连泄漏）";
            }
            if (VirtualNetworkDetected)
            {
                return SystemProxyEnabled ? "系统代理与虚拟网络路径" : "虚拟网络路径";
            }
            if (OtherTunnelDetected)
            {
                return SystemProxyEnabled ? "系统代理与其他 VPN/TUN" : "其他 VPN/TUN";
            }
            if (TunDetected)
            {
                return SystemProxyEnabled ? "系统代理与 TUN" : "TUN";
            }
            return SystemProxyEnabled ? "系统代理" : "未检测到流量入口";
        }
    }

    public string? RouteWarning
    {
        get
        {
            var endpointWarning = Found && EndpointOwnershipChecked && !EndpointOwnedByMihomo
                ? "该本地代理端口的监听 PID 未归属于已检测的 Mihomo 进程，不会将它归因于 Mihomo。"
                : null;
            string? routeWarning;
            if (RouteLookupUnknown)
            {
                routeWarning = "IP Helper 未能确认全部代表性公网前缀的路由，不能排除未识别的直连路径。";
            }
            else if (SplitTunnelDetected)
            {
                routeWarning = "代表性公网前缀在同一协议族内走不同接口，或 IPv4 / IPv6 路径不一致，存在直连泄漏风险。";
            }
            else if (VirtualNetworkDetected)
            {
                routeWarning = "系统最佳路由由虚拟 Ethernet 承载；仅凭虚拟网卡不能判定为 VPN/TUN。";
            }
            else
            {
                routeWarning = OtherTunnelDetected
                    ? "系统路径由其他 VPN/TUN 承载，不能归因于当前 Mihomo 入口。"
                    : null;
            }

            return endpointWarning is null
                ? routeWarning
                : routeWarning is null
                    ? endpointWarning
                    : $"{endpointWarning} {routeWarning}";
        }
    }
}
