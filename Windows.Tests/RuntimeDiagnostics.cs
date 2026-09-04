using System.Security.Principal;
using System.Text.Json;
using System.Net;
using System.Net.Sockets;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;
using System.Diagnostics;

internal static class RuntimeDiagnostics
{
    // Explicit opt-in real-host CLI check; never invoked by the deterministic suite.
    public static async Task RunAsync(string[] args)
    {
        var report = new Dictionary<string, object?>();
        using var identity = WindowsIdentity.GetCurrent();
        var client = new GuardClient();
        var mutated = false;
        try
        {
            report["User"] = identity.Name;
            report["Administrator"] = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            report["Assembly"] = typeof(GuardClient).Assembly.Location;
            var applications = await ProxyApplicationSelection.FindRunningApplicationsAsync();
            report["Applications"] = applications
                .Where(choice => choice.Label.Contains("ikuuu", StringComparison.OrdinalIgnoreCase) ||
                    choice.Label.Contains("mihomo", StringComparison.OrdinalIgnoreCase)).ToArray();
            var config = new ConfigService().Load();
            var probe = new ProxyProbeService();
            var snapshot = await probe.ProbeAsync(config);
            report["Snapshot"] = snapshot;
            report["HealthRoute"] = HealthCheckService.SelectPrimaryExitRoute(snapshot).ToString();
            report["Discovery"] = await new ConnectionDiscoveryService(probe, new MihomoControllerService()).DiscoverAsync(config);
            var before = await client.GetStatusAsync();
            report["GuardBefore"] = before;
            if (args.Length >= 5 && args[2] == "--exercise-auto-guard")
            {
                if (before.Kind != GuardStatusKind.Disabled || !before.OwnedByCurrentUser)
                    throw new InvalidOperationException("Guard must already be disabled and owned before this opt-in test.");
                var configService = new ConfigService();
                var bytesBefore = File.ReadAllBytes(configService.ConfigPath);
                report["ConfiguredMixedPort"] = config.MixedPort;
                report["ConfiguredApplication"] = config.ProxyExecutablePath;
                if (config.ProxyExecutablePath.Length != 0)
                    throw new InvalidOperationException("This test requires the user's existing automatic configuration, not a hardcoded selection.");
                var pendingExit = new TaskCompletionSource<ExitSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
                using var model = new MainViewModel(configService,
                    new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), client,
                    probe.ProbeAsync, (_, token) => pendingExit.Task.WaitAsync(token), client.GetStatusAsync);
                await model.RefreshGuardStatusAsync();
                var refresh = model.RefreshAsync();
                var pickerCalls = 0;
                try
                {
                    mutated = true;
                    var watch = Stopwatch.StartNew();
                    await model.ToggleGuardAsync(_ =>
                    {
                        ++pickerCalls;
                        throw new InvalidOperationException("Unexpected application/setup prompt in the actual switch flow.");
                    });
                    report["ActivationMilliseconds"] = watch.ElapsedMilliseconds;
                    report["PickerCalls"] = pickerCalls;
                    report["EnabledDuringPendingExitRefresh"] = model.IsBusy && model.GuardEnabled;
                    report["GuardDetail"] = model.GuardDetail;
                    if (!model.GuardEnabled || !model.IsBusy || pickerCalls != 0)
                        throw new InvalidOperationException("Automatic switch flow failed or waited for exit refresh.");
                    var enabled = await client.GetStatusAsync();
                    report["GuardEnabled"] = enabled;
                    if (enabled.Kind != GuardStatusKind.Enabled || enabled.FilterCount < 15)
                        throw new InvalidOperationException("The complete switch flow did not install healthy filters.");
                    using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                    socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31,
                        IPAddress.HostToNetworkOrder(int.Parse(args[3])));
                    socket.Bind(new IPEndPoint(IPAddress.Parse(args[4]), 0));
                    try
                    {
                        await socket.ConnectAsync(IPAddress.Parse("1.1.1.1"), 443).WaitAsync(TimeSpan.FromSeconds(3));
                        throw new InvalidOperationException("Protected physical-interface TCP unexpectedly connected.");
                    }
                    catch (SocketException exception) when (exception.SocketErrorCode == SocketError.AccessDenied)
                    {
                        report["PhysicalTcpDenied"] = exception.NativeErrorCode;
                    }
                }
                finally { pendingExit.TrySetResult(ExitSummary.Unavailable()); }
                await refresh;
                report["EnabledAfterStaleRefresh"] = model.GuardEnabled;
                report["ConfigUnchanged"] = File.ReadAllBytes(configService.ConfigPath).SequenceEqual(bytesBefore);
                if (!model.GuardEnabled || !(bool)report["ConfigUnchanged"]!)
                    throw new InvalidOperationException("Stale refresh overwrote Guard or automatic flow modified unrelated settings.");
                await model.ToggleGuardAsync();
                report["DisabledViaSameSwitchFlow"] = !model.GuardEnabled;
                if (model.GuardEnabled) throw new InvalidOperationException("Switch flow failed to disable.");
            }
            if (args.Length > 3 && args[2] == "--exercise-guard")
            {
                if (before.Kind != GuardStatusKind.Disabled || !before.OwnedByCurrentUser)
                    throw new InvalidOperationException("Guard must already be disabled and owned before this opt-in test.");
                var testConfig = config.Clone();
                testConfig.ProxyExecutablePath = ProxyApplicationSelection.NormalizePath(args[3]);
                if (!applications.Any(choice => string.Equals(choice.ExecutablePath, testConfig.ProxyExecutablePath, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidOperationException("The selected core is missing from ordinary-user application discovery.");
                // Set before sending: an uncertain response must still trigger cleanup.
                mutated = true;
                await client.EnableAsync(testConfig);
                var enabled = await client.GetStatusAsync();
                report["GuardEnabled"] = enabled;
                if (enabled.Kind != GuardStatusKind.Enabled || enabled.FilterCount < 15)
                    throw new InvalidOperationException("The UI's managed Guard client did not enable healthy filters.");
                if (args.Length >= 6)
                {
                    using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                    socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, // Windows IP_UNICAST_IF
                        IPAddress.HostToNetworkOrder(int.Parse(args[4])));
                    socket.Bind(new IPEndPoint(IPAddress.Parse(args[5]), 0));
                    try
                    {
                        await socket.ConnectAsync(IPAddress.Parse("1.1.1.1"), 443).WaitAsync(TimeSpan.FromSeconds(3));
                        throw new InvalidOperationException("Protected ordinary-user physical-interface TCP unexpectedly connected.");
                    }
                    catch (SocketException exception) when (exception.SocketErrorCode == SocketError.AccessDenied)
                    {
                        report["PhysicalTcpDenied"] = exception.NativeErrorCode;
                    }
                }
            }
            report["Success"] = true;
        }
        catch (Exception exception)
        {
            report["Error"] = exception.ToString();
            report["Success"] = false;
            Environment.ExitCode = 1;
        }
        finally
        {
            if (mutated)
            {
                try { await client.DisableAsync(); }
                catch (Exception exception) { report["CleanupError"] = exception.ToString(); Environment.ExitCode = 2; }
            }
            report["GuardAfter"] = await client.GetStatusAsync();
            await File.WriteAllTextAsync(args[1], JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        }
    }
}
