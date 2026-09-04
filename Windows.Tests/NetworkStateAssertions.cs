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
        Console.WriteLine("Network state: WFP disconnect, HTTP failure, bounded loading, storm and recovery passed.");
    }
}
