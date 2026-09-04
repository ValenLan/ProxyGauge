using System.IO;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed record GuardApplicationRequest(
    string Reason, IReadOnlyList<ProxyApplicationChoice> Applications, string PreviousPath);

// The button and CLI regression host use this same port-independent activation flow.
public sealed class GuardActivationService
{
    private readonly Func<CancellationToken, Task<IReadOnlyList<ProxyApplicationChoice>>> _discover;
    private readonly Func<string, CancellationToken, Task> _enable;
    private readonly Func<string, CancellationToken, Task<string>>? _enableAutomatic;

    public GuardActivationService(GuardClient client) : this(
        ProxyApplicationSelection.FindRunningApplicationsAsync,
        (path, token) => client.EnableAsync(new AppConfig { ProxyExecutablePath = path }, token),
        client.EnableAutomaticAsync) { }

    internal GuardActivationService(
        Func<CancellationToken, Task<IReadOnlyList<ProxyApplicationChoice>>> discover,
        Func<string, CancellationToken, Task> enable,
        Func<string, CancellationToken, Task<string>>? enableAutomatic = null)
    {
        _discover = discover;
        _enable = enable;
        _enableAutomatic = enableAutomatic;
    }

    public async Task<string?> EnableAsync(string configuredPath,
        Func<GuardApplicationRequest, Task<string?>>? chooseApplication,
        CancellationToken cancellationToken, bool forceChoice = false)
    {
        var path = ProxyApplicationSelection.NormalizePath(configuredPath);
        IReadOnlyList<ProxyApplicationChoice>? applications = null;
        var reason = "PROXY_NOT_RUNNING";
        if (path.Length == 0 && !forceChoice)
        {
            if (_enableAutomatic is not null)
            {
                try { return await _enableAutomatic("AUTO", cancellationToken); }
                catch (GuardCommandException exception) when (exception.Code is "PROXY_NOT_RUNNING" or "PROXY_AMBIGUOUS")
                { reason = exception.Code; }
            }
            applications = await _discover(cancellationToken);
            var cores = AutomaticCandidates(applications);
            if (cores.Count == 1 && _enableAutomatic is null) path = cores[0].ExecutablePath;
            else if (cores.Count > 1) reason = "PROXY_AMBIGUOUS";
        }

        if (path.Length > 0 && !forceChoice)
        {
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                await _enable(path, cancellationToken);
                return path;
            }
            catch (GuardCommandException exception) when (exception.Code == "PROXY_NOT_RUNNING")
            {
                // A pinned choice must never silently transfer its trust to another app.
                applications = null;
            }
        }

        if (forceChoice) reason = "PROXY_AMBIGUOUS";
        if (chooseApplication is null) throw new GuardCommandException(reason);
        applications ??= await _discover(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var chosen = await chooseApplication(new GuardApplicationRequest(reason,
            AutomaticCandidates(applications), configuredPath));
        cancellationToken.ThrowIfCancellationRequested();
        if (chosen is null) return null; // Cancel is a no-op, never a default permit.
        path = ProxyApplicationSelection.NormalizePath(chosen);
        if (path.Length == 0) throw new GuardCommandException("INVALID_PROXY_PATH");
        if (configuredPath.Length == 0 && IsKnownCore(path) && _enableAutomatic is not null)
            return await _enableAutomatic(path, cancellationToken);
        await _enable(path, cancellationToken); // Service revalidates the process before the WFP transaction.
        return path;
    }

    internal static IReadOnlyList<ProxyApplicationChoice> AutomaticCandidates(
        IEnumerable<ProxyApplicationChoice> applications) => applications
        .Where(choice => IsKnownCore(choice.ExecutablePath))
        .DistinctBy(choice => choice.ExecutablePath, StringComparer.OrdinalIgnoreCase)
        .OrderByDescending(choice => IsClashCore(Path.GetFileNameWithoutExtension(choice.ExecutablePath)))
        .ThenBy(choice => choice.ExecutablePath, StringComparer.OrdinalIgnoreCase).ToArray();

    internal static bool IsKnownCore(string path)
    {
        try { if (ProxyApplicationSelection.NormalizePath(path).Length == 0) return false; }
        catch (InvalidDataException) { return false; }
        var name = Path.GetFileNameWithoutExtension(path);
        // Exact known network-core names only: no '*vpn*', '*core*', launchers, or port owners.
        return IsClashCore(name) || new[] { "iKuuuVPNCore", "sing-box", "singbox", "xray", "v2ray" }
            .Contains(name, StringComparer.OrdinalIgnoreCase);
    }

    private static bool IsClashCore(string name) =>
        new[] { "clash", "clash-meta", "mihomo", "verge-mihomo" }
            .Contains(name, StringComparer.OrdinalIgnoreCase);
}
