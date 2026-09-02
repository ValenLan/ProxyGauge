using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

internal readonly record struct ConnectionCandidate(
    string Host,
    int Port,
    string Source,
    bool IsExplicitSystemProxy);

public sealed class ConnectionDiscoveryService
{
    private static readonly int[] CommonMixedPorts = [7890, 7897];
    internal static IReadOnlyList<int> FallbackMixedPorts => CommonMixedPorts;
    private readonly ProxyProbeService _probeService;
    private readonly MihomoControllerService _controllerService;

    public ConnectionDiscoveryService(
        ProxyProbeService probeService,
        MihomoControllerService controllerService)
    {
        _probeService = probeService;
        _controllerService = controllerService;
    }

    public async Task<ConnectionDiscoveryResult> DiscoverAsync(
        AppConfig current,
        CancellationToken cancellationToken = default)
    {
        var systemProxy = _probeService.IsSystemProxyEnabled();
        var tunnelKindTask = _probeService.DetectTunnelKindAsync(cancellationToken);
        var candidates = new List<ConnectionCandidate>();

        using (var config = await _controllerService.TryGetJsonAsync("/configs", cancellationToken))
        {
            if (TryReadMixedPort(config?.RootElement, out var controllerPort))
            {
                candidates.Add(new ConnectionCandidate(
                    "127.0.0.1",
                    controllerPort,
                    "Mihomo 本地控制接口",
                    IsExplicitSystemProxy: false));
            }
        }

        if (TryReadSystemProxy(out var proxyHost, out var proxyPort))
        {
            candidates.Add(new ConnectionCandidate(
                proxyHost,
                proxyPort,
                "Windows 系统代理",
                IsExplicitSystemProxy: true));
        }

        if (LocalEndpointPolicy.IsLoopbackHost(current.MixedHost))
        {
            candidates.Add(new ConnectionCandidate(
                LocalEndpointPolicy.NormalizeLoopbackHost(current.MixedHost),
                current.MixedPort,
                "ProxyGauge 当前设置",
                IsExplicitSystemProxy: false));
        }

        candidates.AddRange(CommonMixedPorts.Select(port =>
            new ConnectionCandidate(
                "127.0.0.1",
                port,
                "常用 Mihomo 端口",
                IsExplicitSystemProxy: false)));
        var tunnelKind = await tunnelKindTask;
        var coreProcessIds = _probeService.GetProxyCoreProcessIds();

        foreach (var candidateGroup in candidates.GroupBy(candidate => (candidate.Host, candidate.Port)))
        {
            var probeCandidate = candidateGroup.First();
            var attribution = await TcpListenerOwnership.ProbeAsync(
                probeCandidate.Host,
                probeCandidate.Port,
                coreProcessIds,
                1,
                cancellationToken);
            var hasExplicitSystemProxy = candidateGroup.Any(candidate => candidate.IsExplicitSystemProxy);
            if (!ShouldAcceptCandidate(hasExplicitSystemProxy, attribution))
            {
                continue;
            }

            var ownedByMihomo = attribution == TcpListenerAttribution.MihomoOwned;
            var candidate = ownedByMihomo
                ? probeCandidate
                : candidateGroup.First(value => value.IsExplicitSystemProxy);
            return new ConnectionDiscoveryResult(
                true,
                candidate.Host,
                candidate.Port,
                ownedByMihomo ? "Mihomo / Clash Verge" : "本地代理（未归属 Mihomo）",
                candidate.Source,
                systemProxy,
                tunnelKind == TunnelKind.Mihomo,
                tunnelKind == TunnelKind.Other,
                tunnelKind == TunnelKind.Split,
                tunnelKind == TunnelKind.VirtualNetwork,
                tunnelKind == TunnelKind.Unknown,
                EndpointOwnershipChecked: true,
                EndpointOwnedByMihomo: ownedByMihomo);
        }

        return new ConnectionDiscoveryResult(
            false,
            "127.0.0.1",
            current.MixedPort,
            coreProcessIds.Count > 0 ? "Mihomo / Clash Verge" : "未发现代理核心",
            "自动检测未找到可用入口",
            systemProxy,
            tunnelKind == TunnelKind.Mihomo,
            tunnelKind == TunnelKind.Other,
            tunnelKind == TunnelKind.Split,
            tunnelKind == TunnelKind.VirtualNetwork,
            tunnelKind == TunnelKind.Unknown);
    }

    internal static bool ShouldAcceptCandidate(
        bool isExplicitSystemProxy,
        TcpListenerAttribution attribution) =>
        attribution == TcpListenerAttribution.MihomoOwned ||
        (isExplicitSystemProxy && attribution == TcpListenerAttribution.OtherOrUnknown);

    private static bool TryReadMixedPort(JsonElement? root, out int port)
    {
        port = 0;
        return root is { ValueKind: JsonValueKind.Object } &&
               root.Value.TryGetProperty("mixed-port", out var value) &&
               value.TryGetInt32(out port) && port is > 0 and <= 65535;
    }

    private static bool TryReadSystemProxy(out string host, out int port)
    {
        host = string.Empty;
        port = 0;
        var proxy = ProxyProbeService.ReadSystemProxyConfiguration();
        if (!proxy.ExplicitCoversHttps ||
            !proxy.HasValidExplicitEndpoint ||
            !LocalEndpointPolicy.IsLoopbackHost(proxy.ExplicitHost))
        {
            return false;
        }

        host = LocalEndpointPolicy.NormalizeLoopbackHost(proxy.ExplicitHost);
        port = proxy.ExplicitPort!.Value;
        return true;
    }
}
