using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

internal static class GuardActivationAssertions
{
    private const string Core = @"C:\Program Files\iKuuuVPN\iKuuuVPNCore.exe";
    private const string Clash = @"C:\Clash\mihomo.exe";
    private static ProxyApplicationChoice App(string path) => new(path, path);
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static async Task RunAsync()
    {
        var discovered = new[] { App(Core), App(Core.ToUpperInvariant()),
            App(@"C:\Clash\clash-verge-service.exe"), App(@"E:\vpn\iKuuuVPN.exe"),
            App(@"E:\vpn\iKuuuVPNHelperService.exe"), App(@"C:\unknown\unrelatedcore.exe"),
            App(@"C:\unknown\vpn.exe"), App(@"\\server\mihomo.exe") };
        Check(GuardActivationService.AutomaticCandidates(discovered) is [{ ExecutablePath: Core }],
            "Automatic discovery must deduplicate cores and exclude launchers, helpers, arbitrary VPN/core names and remote paths.");

        string? enabledPath = null;
        var enableCalls = 0;
        var pickerCalls = 0;
        Task Enable(string path, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            enabledPath = path;
            ++enableCalls;
            return Task.CompletedTask;
        }
        var automatic = new GuardActivationService(_ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>(discovered), Enable);
        var result = await automatic.EnableAsync("", _ => { ++pickerCalls; throw new Exception("Unexpected picker"); }, default);
        Check(result == Core && enabledPath == Core && enableCalls == 1 && pickerCalls == 0,
            "A unique iKuuu core must enable without any port/setup/picker step.");

        var multiple = new GuardActivationService(_ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([App(Core), App(Clash)]), Enable);
        await multiple.EnableAsync("", request =>
        {
            ++pickerCalls;
            Check(request.Reason == "PROXY_AMBIGUOUS" && request.Applications.Count == 2 &&
                request.Applications[0].ExecutablePath == Clash, "Clash is first but multiple cores require a choice.");
            return Task.FromResult<string?>(Core);
        }, default);
        Check(enabledPath == Core && enableCalls == 2 && pickerCalls == 1, "Explicit selection must enable exactly once.");
        Check(await multiple.EnableAsync("", _ => Task.FromResult<string?>(null), default) is null && enableCalls == 2,
            "Cancel must not install or replace any rules.");

        var none = new GuardActivationService(_ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([]), Enable);
        await none.EnableAsync("", request =>
        {
            Check(request.Reason == "PROXY_NOT_RUNNING" && request.Applications.Count == 0,
                "No core must request only a core, never a port.");
            return Task.FromResult<string?>(null);
        }, default);
        Check(enableCalls == 2, "Missing core must leave protection state unchanged.");
        await automatic.EnableAsync(@"C:\custom\private-proxy.exe", null, default);
        Check(enabledPath == @"C:\custom\private-proxy.exe", "Pinned custom selections must not be silently replaced.");

        var missingPinned = new GuardActivationService(_ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([App(Core)]),
            (path, token) => path == Clash ? throw new GuardCommandException("PROXY_NOT_RUNNING") : Enable(path, token));
        var callsBeforeMissing = enableCalls;
        await missingPinned.EnableAsync(Clash, request =>
        {
            Check(request.PreviousPath == Clash, "A stopped pinned core requires explicit permission to switch trust.");
            return Task.FromResult<string?>(null);
        }, default);
        Check(enableCalls == callsBeforeMissing, "Do not auto-fallback from a stopped pinned application.");

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try { await automatic.EnableAsync("", null, cancelled.Token); throw new Exception("Cancellation ignored"); }
        catch (OperationCanceledException) { }

        var autoRequests = new List<string>();
        var nativeAutomatic = new GuardActivationService(
            _ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([App(Core), App(Clash)]), Enable,
            (seed, _) => { autoRequests.Add(seed); return Task.FromResult(seed == "AUTO" ? Clash : seed); });
        Check(await nativeAutomatic.EnableAsync("", null, default) == Clash && autoRequests.SequenceEqual(["AUTO"]),
            "Automatic mode must use the service's active-entry detection, not pick an arbitrary local candidate.");
        await nativeAutomatic.EnableAsync("", _ => Task.FromResult<string?>(Core), default, forceChoice: true);
        Check(autoRequests.SequenceEqual(["AUTO", Core]), "Changing the current core must preserve native automatic follow.");
        var autoCallsBeforePin = autoRequests.Count;
        await nativeAutomatic.EnableAsync(Clash, null, default);
        Check(autoRequests.Count == autoCallsBeforePin && enabledPath == Clash, "An explicit configured pin must never become automatic.");
        var ambiguousNative = new GuardActivationService(
            _ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([App(Core), App(Clash)]), Enable,
            (seed, _) => seed == "AUTO" ? throw new GuardCommandException("PROXY_AMBIGUOUS") : Task.FromResult(seed));
        Check(await ambiguousNative.EnableAsync("", request =>
            { Check(request.Reason == "PROXY_AMBIGUOUS", "Ambiguous native detection must request only an app choice."); return Task.FromResult<string?>(Core); }, default) == Core,
            "A native ambiguity must resolve through the selected known core, without disabling protection.");

        var testDirectory = Directory.CreateTempSubdirectory("proxygauge-guard-click-");
        try
        {
            var configService = new ConfigService(Path.Combine(testDirectory.FullName, "config.json"));
            configService.Save(new AppConfig { MixedPort = 7897 }); // Deliberately stale, non-listening port.
            var configBytes = File.ReadAllBytes(configService.ConfigPath);
            var status = new GuardStatus(GuardStatusKind.Disabled, true, 0);
            var releaseExit = new TaskCompletionSource<ExitSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
            var probe = new ProxyProbeService();
            var activation = new GuardActivationService(_ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>(discovered),
                (path, token) => { enabledPath = path; ++enableCalls; status = new(GuardStatusKind.Enabled, true, 17); return Task.CompletedTask; });
            using var model = new MainViewModel(configService,
                new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), new GuardClient(),
                (_, _) => Task.FromException<ProxySnapshot>(new IOException("No endpoint needed")),
                (_, token) => releaseExit.Task.WaitAsync(token),
                _ => Task.FromResult(status), guardActivation: activation,
                disableGuard: _ => { status = new(GuardStatusKind.Disabled, true, 0); return Task.CompletedTask; });
            var refresh = model.RefreshAsync();
            Check(model.IsBusy && model.CanChangeGuard, "Public-IP refresh must not disable the Guard switch.");
            var changes = 0;
            model.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(model.GuardEnabled)) ++changes; };
            await model.ToggleGuardAsync(_ => throw new Exception("The actual button path must not request setup for iKuuu"))
                .WaitAsync(TimeSpan.FromSeconds(2));
            Check(model.GuardEnabled && model.GuardValue == "已开启" && model.IsBusy &&
                    model.GuardDetail.Contains("iKuuuVPNCore") && enabledPath == Core,
                "The complete button flow must auto-enable while the public-IP task is still blocked.");
            releaseExit.SetResult(ExitSummary.Unavailable());
            await refresh;
            Check(model.GuardEnabled, "A pre-enable refresh must not overwrite the new Guard state.");
            Check(File.ReadAllBytes(configService.ConfigPath).SequenceEqual(configBytes),
                "Automatic enable must leave stale port and unrelated settings byte-for-byte unchanged.");
            status = status with { AutomaticSelection = true, ProxyExecutablePath = Core, SelectionRequired = true };
            await model.RefreshGuardStatusAsync();
            Check(model.GuardEnabled && model.GuardApplicationLabel == "选择当前代理" &&
                    model.GuardDetail.Contains("保护继续生效"),
                "Ambiguous live cores must expose an actionable choice while retaining enabled protection.");
            await model.ToggleGuardAsync();
            Check(!model.GuardEnabled && changes >= 2, "The same switch flow must turn protection off and notify its binding.");

            // A known-core picker choice retains automatic mode; unrelated config remains unchanged.
            using var explicitModel = new MainViewModel(configService,
                new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), new GuardClient(),
                (_, _) => Task.FromException<ProxySnapshot>(new IOException()), (_, _) => Task.FromResult(ExitSummary.Unavailable()),
                _ => Task.FromResult(status), guardActivation: new GuardActivationService(
                    _ => Task.FromResult<IReadOnlyList<ProxyApplicationChoice>>([App(Core), App(Clash)]),
                    (_, _) => { status = new(GuardStatusKind.Enabled, true, 17); return Task.CompletedTask; }));
            await explicitModel.EnableGuardAsync(_ => Task.FromResult<string?>(null));
            Check(!explicitModel.GuardEnabled && File.ReadAllBytes(configService.ConfigPath).SequenceEqual(configBytes),
                "Cancel in the complete flow must neither save settings nor enable rules.");
            await explicitModel.EnableGuardAsync(_ => Task.FromResult<string?>(Core));
            Check(explicitModel.GuardEnabled && configService.Load().ProxyExecutablePath == "" && configService.Load().MixedPort == 7897,
                "Choosing the current known core must preserve automatic mode and the old port.");
        }
        finally { testDirectory.Delete(recursive: true); }
        Console.WriteLine("Guard activation: auto-core, ambiguity, cancel, pinning, stale port and concurrent refresh passed.");
    }
}
