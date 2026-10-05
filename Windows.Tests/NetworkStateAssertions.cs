using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

internal static class NetworkStateAssertions
{
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    internal static async Task RunAsync()
    {
        using var blocked = new HttpClient(new Handler((_, _) => throw new HttpRequestException("WFP blocked", new SocketException(10013))));
        var result = await ExitSummaryService.ResolveWithClientAsync(blocked);
        Check(result.State == ExitSummaryState.Disconnected && result.Address == "已断开网络连接" && !result.HasIpVersion,
            "WFP rejection must settle to disconnected, with no IP chip.");
        using var failedService = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))));
        Check((await ExitSummaryService.ResolveWithClientAsync(failedService)).State == ExitSummaryState.Unavailable,
            "An HTTP service failure must not be mislabeled as internet disconnection.");
        using var mixed = new HttpClient(new Handler((request, _) => request.RequestUri!.Host == "ipapi.co"
            ? Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))
            : throw new HttpRequestException("route blocked", new SocketException(10013))));
        Check((await ExitSummaryService.ResolveWithClientAsync(mixed)).State == ExitSummaryState.Unavailable,
            "At least one HTTP response is evidence against declaring the whole current path disconnected.");
        var directory = Directory.CreateTempSubdirectory("proxygauge-network-state-");
        try
        {
            var config = new ConfigService(Path.Combine(directory.FullName, "config.json"));
            config.Save(new AppConfig());
            var probe = new ProxyProbeService();
            var release = new TaskCompletionSource<ExitSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var model = new MainViewModel(config,
                new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), new GuardClient(),
                (_, _) => Task.FromException<ProxySnapshot>(new IOException()), (_, token) => release.Task.WaitAsync(token),
                _ => Task.FromResult(GuardStatus.Unavailable()), exitSettlementTimeout: TimeSpan.FromMilliseconds(80));
            var refresh = model.RefreshExitAsync();
            await Task.Delay(120);
            Check(model.ExitAddress == "暂时无法读取", "A refresh storm or stalled resolver must not leave an endless spinner.");
            model.InvalidateExitSummary();
            var next = model.RefreshExitAsync();
            Check(model.ExitAddress != "正在检测", "Repeated invalidations must not reset an expired settlement deadline.");
            model.NotifyNetworkUnavailable();
            Check(model.ExitAddress == "已断开网络连接", "Physical disconnection must immediately clear stale IP/loading state.");
            var recovery = model.RefreshExitAsync();
            Check(model.ExitAddress == "已断开网络连接", "Background retries must preserve the disconnected label until a result arrives.");
            release.TrySetResult(new ExitSummary("1.1.1.1", "Australia"));
            await Task.WhenAll(refresh, next, recovery);
            Check(model.ExitAddress == "1.1.1.1" && model.HasExitIpVersion, "A successful current-generation recovery must replace disconnected state.");
            model.InvalidateExitSummary();
            Check(model.ExitAddress == "等待重新检测", "Inactive/debounced invalidation must not claim a query is running.");
        }
        finally { directory.Delete(recursive: true); }
        await RunOutageRecheckAsync();
        Console.WriteLine("Network state: WFP disconnect, HTTP failure, bounded loading, storm and recovery passed.");
    }

    // A brief outage can end before any route read records a different fingerprint.
    private static async Task RunOutageRecheckAsync()
    {
        var directory = Directory.CreateTempSubdirectory("proxygauge-outage-recheck-");
        try
        {
            var config = new ConfigService(Path.Combine(directory.FullName, "config.json"));
            config.Save(new AppConfig());
            var store = new ExitSummaryStore(config.ConfigPath);
            var verified = new ExitSummary("1.1.1.1", "Australia");
            Func<CancellationToken, Task<ExitSummary>> resolve = _ => Task.FromResult(verified);
            var probe = new ProxyProbeService();
            using var model = new MainViewModel(config,
                new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), new GuardClient(),
                (_, _) => Task.FromException<ProxySnapshot>(new IOException()), (_, token) => resolve(token),
                _ => Task.FromResult(GuardStatus.Unavailable()), exitSettlementTimeout: TimeSpan.FromMilliseconds(80));
            var path = new string('a', 64);
            Check(!model.ObserveExitPathFingerprint(path), "The first route fingerprint must remain a baseline.");
            await model.RefreshExitAsync();
            Check(model.ExitAddress == "1.1.1.1" && store.Load().Summary?.Address == "1.1.1.1",
                "The outage scenarios must start from a verified, persisted exit.");

            model.NotifyNetworkAvailable();
            Check(!model.ObserveExitPathFingerprint(path), "Availability without an observed outage must not query.");

            model.NotifyNetworkUnavailable();
            Check(!model.ObserveExitPathFingerprint(path), "An unchanged route read while still offline must not query.");
            Check(model.ExitAddress == "已断开网络连接", "An ongoing outage must keep the disconnected label.");
            model.NotifyNetworkAvailable();
            Check(model.ExitAddress == "等待重新检测", "A restored network must not keep claiming disconnection.");
            Check(model.ObserveExitPathFingerprint(path),
                "A brief outage missed by the route fingerprint must still re-verify the cleared exit.");
            Check(store.Load().Summary is null, "The post-outage re-check must clear the pre-outage exit like a path change.");
            Check(!model.ObserveExitPathFingerprint(path), "The post-outage re-check must be requested only once.");
            await model.RefreshExitAsync();

            model.NotifyNetworkUnavailable();
            model.NotifyNetworkAvailable();
            await model.RefreshExitAsync();
            Check(!model.ObserveExitPathFingerprint(path),
                "A lookup that verified the restored path before the next route read must not be repeated.");

            model.NotifyNetworkUnavailable();
            await model.RefreshExitAsync();
            model.NotifyNetworkAvailable();
            Check(!model.ObserveExitPathFingerprint(path), "An outage already followed by a verified lookup must not query again.");

            var stalled = new TaskCompletionSource<ExitSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
            resolve = token => stalled.Task.WaitAsync(token);
            var pending = model.RefreshExitAsync();
            await Task.Delay(150);
            Check(model.ExitAddress == "暂时无法读取", "The settlement deadline must expire for the stalled lookup.");
            model.NotifyNetworkUnavailable();
            await pending;
            model.NotifyNetworkAvailable();
            Check(model.ExitAddress == "暂时无法读取",
                "An expired settlement must not turn back into a pending state after reconnecting.");
            Check(model.ObserveExitPathFingerprint(path), "The expired-settlement outage must still request one re-check.");
            resolve = _ => Task.FromResult(verified);
            await model.RefreshExitAsync();
            Check(model.ExitAddress == "1.1.1.1", "A successful re-check must replace the expired label.");

            resolve = _ => Task.FromResult(ExitSummary.Disconnected());
            await model.RefreshExitAsync();
            model.NotifyNetworkAvailable();
            Check(model.ExitAddress == "已断开网络连接" && !model.ObserveExitPathFingerprint(path),
                "Availability must not mask a resolver-confirmed disconnection such as a Kill Switch block.");
        }
        finally { directory.Delete(recursive: true); }
    }
}
