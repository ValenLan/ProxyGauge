using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text.Json;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

internal static class GuardHandoverDiagnostics
{
    // Explicit CLI opt-in. Changes only the selected Guard app, never the user's VPN/system proxy settings.
    internal static async Task RunAsync(string[] args)
    {
        var report = new Dictionary<string, object?>();
        var client = new GuardClient();
        GuardStatus? before = null;
        Process? coreA = null, coreB = null;
        var changed = false;
        var configService = new ConfigService();
        var config = configService.Load();
        var target = args.Length == 8 ? args[7] : "1.1.1.1";
        report["PhysicalTarget"] = target;
        var savedConfig = File.ReadAllBytes(configService.ConfigPath);
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            report["Administrator"] = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            report["Assembly"] = typeof(GuardClient).Assembly.Location;
            before = await client.GetStatusAsync();
            report["Before"] = before;
            if (!before.IsHealthy || !before.OwnedByCurrentUser || before.ProxyExecutablePath.Length == 0 || config.ProxyExecutablePath.Length != 0)
                throw new InvalidOperationException("This test requires the user's existing healthy, owned protection and automatic GUI configuration.");
            var systemProxy = ProxyProbeService.ReadSystemProxyConfiguration();
            if (systemProxy.Enabled) throw new InvalidOperationException("A live explicit/PAC/environment proxy is present; do not redirect the user's active system entry for this fixture test.");
            var coreArgs = new[] { "core", "39341", target, "443", args[5], args[6] };
            coreA = Start(args[2], coreArgs);
            coreArgs[1] = "39342";
            coreB = Start(args[3], coreArgs);
            await WaitForListenerAsync(39341);
            await WaitForListenerAsync(39342);
            var probe = new ProxyProbeService();
            using var model = new MainViewModel(configService, probe,
                new HealthCheckService(probe, new MihomoPlanInspectionService(new MihomoControllerService())), client);
            await model.RefreshGuardStatusAsync();
            changed = true;
            await model.SwitchGuardApplicationAsync(_ => Task.FromResult<string?>(args[2]));
            report["SelectedA"] = await client.GetStatusAsync();
            if (!model.GuardEnabled || ((GuardStatus)report["SelectedA"]!).ProxyExecutablePath != args[2].ToLowerInvariant())
                throw new InvalidOperationException("Shared switch flow did not select A without disabling.");
            var coreAResult = await CoreProbeAsync(39341);
            report["CoreAResult"] = coreAResult;
            report["CoreAConnected"] = coreAResult.GetProperty("outcome").GetString() == "connected";
            if (!(bool)report["CoreAConnected"]!) throw new InvalidOperationException("Trusted core A cannot reach the physical network.");
            if ((await CoreProbeAsync(39342)).GetProperty("error").GetInt32() != 10013)
                throw new InvalidOperationException("Unselected core B inherited an unexpected permit.");

            using var flood = Start(args[4], ["flood", target, "443", args[5], args[6], "300"]);
            var floodOutput = flood.StandardOutput.ReadToEndAsync();
            await Task.Delay(200);
            await model.SwitchGuardApplicationAsync(_ => Task.FromResult<string?>(args[3]));
            report["SelectedB"] = await client.GetStatusAsync();
            if (!model.GuardEnabled) throw new InvalidOperationException("Protection switched off during handover.");
            var coreBResult = await CoreProbeAsync(39342);
            report["CoreBResult"] = coreBResult;
            report["CoreBConnected"] = coreBResult.GetProperty("outcome").GetString() == "connected";
            if (!(bool)report["CoreBConnected"]!) throw new InvalidOperationException("Trusted core B cannot reach the physical network.");
            report["OldCoreDenied"] = (await CoreProbeAsync(39341)).GetProperty("error").GetInt32();
            if ((int)report["OldCoreDenied"]! != 10013) throw new InvalidOperationException("Old core permit survived handover.");
            await flood.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(12));
            var lines = (await floodOutput).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            report["DirectAttempts"] = lines.Length;
            report["AllDirectDenied"] = lines.Length == 300 && lines.All(line => JsonDocument.Parse(line).RootElement.GetProperty("error").GetInt32() == 10013);
            if (!(bool)report["AllDirectDenied"]!) throw new InvalidOperationException("An ordinary physical TCP attempt was not denied during handover.");

            using var handler = new SocketsHttpHandler { UseProxy = false,
                ConnectCallback = async (_, token) =>
                {
                    var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                    try
                    {
                        socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(int.Parse(args[5])));
                        socket.Bind(new IPEndPoint(IPAddress.Parse(args[6]), 0));
                        await socket.ConnectAsync(IPAddress.Parse(target), 443, token);
                        return new NetworkStream(socket, ownsSocket: true);
                    }
                    catch { socket.Dispose(); throw; }
                } };
            using var blockedHttp = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3) };
            report["DisconnectedSummary"] = await ExitSummaryService.ResolveWithClientAsync(blockedHttp);
            if (((ExitSummary)report["DisconnectedSummary"]!).State != ExitSummaryState.Disconnected)
                throw new InvalidOperationException("Real WFP rejection did not settle the IP card to disconnected.");
            report["ConfigUnchanged"] = File.ReadAllBytes(configService.ConfigPath).SequenceEqual(savedConfig);
            if (!(bool)report["ConfigUnchanged"]!) throw new InvalidOperationException("Switching the current core changed automatic configuration.");
            report["Success"] = true;
        }
        catch (Exception exception) { report["Success"] = false; report["Error"] = exception.ToString(); Environment.ExitCode = 1; }
        finally
        {
            if (changed && before is not null)
            {
                try
                {
                    // Preserve the user's ON state and original trusted core; migrate automatic configuration to native auto-follow.
                    await client.EnableAutomaticAsync(before.ProxyExecutablePath);
                }
                catch (Exception exception) { report["RestoreError"] = exception.ToString(); Environment.ExitCode = 2; }
            }
            foreach (var process in new[] { coreA, coreB })
                if (process is not null) { if (!process.HasExited) process.Kill(); process.Dispose(); }
            report["After"] = await client.GetStatusAsync();
            await File.WriteAllTextAsync(args[1], JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    private static Process Start(string executable, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in arguments) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("Could not start the scoped CLI probe.");
    }
    private static async Task WaitForListenerAsync(int port)
    {
        for (var i = 0; i < 40; i++)
        {
            try { using var tcp = new TcpClient(); await tcp.ConnectAsync(IPAddress.Loopback, port); return; }
            catch (SocketException) { await Task.Delay(50); }
        }
        throw new TimeoutException("Fixture listener did not start.");
    }
    private static async Task<JsonElement> CoreProbeAsync(int port)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, port);
        using var reader = new StreamReader(tcp.GetStream());
        var line = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
        using var json = JsonDocument.Parse(line!);
        return json.RootElement.Clone();
    }
}
