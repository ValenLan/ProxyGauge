using System.Text.Json;
using Microsoft.Win32;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class ConnectionDiscoveryService
{
    private static readonly int[] CommonMixedPorts = [7890, 7897, 1080];
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
        var tunDetectedTask = _probeService.DetectTunAsync(cancellationToken);
        var candidates = new List<(string Host, int Port, string Source)>();

        using (var config = await _controllerService.TryGetJsonAsync("/configs", cancellationToken))
        {
            if (TryReadMixedPort(config?.RootElement, out var controllerPort))
            {
                candidates.Add(("127.0.0.1", controllerPort, "Mihomo 本地控制接口"));
            }
        }

        if (TryReadSystemProxy(out var proxyHost, out var proxyPort))
        {
            candidates.Add((proxyHost, proxyPort, "Windows 系统代理"));
        }

        if (LocalEndpointPolicy.IsLoopbackHost(current.MixedHost))
        {
            candidates.Add((
                LocalEndpointPolicy.NormalizeLoopbackHost(current.MixedHost),
                current.MixedPort,
                "ProxyGauge 当前设置"));
        }

        candidates.AddRange(CommonMixedPorts.Select(port =>
            ("127.0.0.1", port, "常用 Mihomo 端口")));

        foreach (var candidate in candidates.DistinctBy(value => (value.Host, value.Port)))
        {
            if (await _probeService.CanConnectAsync(
                    candidate.Host,
                    candidate.Port,
                    1,
                    cancellationToken))
            {
                return new ConnectionDiscoveryResult(
                    true,
                    candidate.Host,
                    candidate.Port,
                    _probeService.CountProxyCores() > 0 ? "Mihomo / Clash Verge" : "本地代理",
                    candidate.Source,
                    systemProxy,
                    await tunDetectedTask);
            }
        }

        return new ConnectionDiscoveryResult(
            false,
            "127.0.0.1",
            current.MixedPort,
            _probeService.CountProxyCores() > 0 ? "Mihomo / Clash Verge" : "未发现代理核心",
            "自动检测未找到可用入口",
            systemProxy,
            await tunDetectedTask);
    }

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
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            if (Convert.ToInt32(key?.GetValue("ProxyEnable") ?? 0) != 1)
            {
                return false;
            }

            var raw = Convert.ToString(key?.GetValue("ProxyServer"))?.Trim();
            if (string.IsNullOrWhiteSpace(raw)) return false;
            var entries = raw.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            foreach (var entry in entries.Prepend(raw))
            {
                var endpoint = entry.Contains('=') ? entry[(entry.IndexOf('=') + 1)..] : entry;
                if (!Uri.TryCreate($"http://{endpoint}", UriKind.Absolute, out var uri) ||
                    !LocalEndpointPolicy.IsLoopbackHost(uri.Host) || uri.Port is <= 0 or > 65535)
                {
                    continue;
                }

                host = "127.0.0.1";
                port = uri.Port;
                return true;
            }
        }
        catch
        {
            // Invalid or policy-controlled proxy values fall back to local port probing.
        }

        return false;
    }
}
