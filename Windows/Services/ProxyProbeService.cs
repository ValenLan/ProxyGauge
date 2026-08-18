using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Win32;
using PuffRoute.Models;

namespace PuffRoute.Services;

public sealed class ProxyProbeService
{
    private static readonly string[] CoreProcessNames =
    [
        "verge-mihomo",
        "mihomo",
        "clash-meta"
    ];

    private static readonly string[] TunKeywords =
    [
        "mihomo",
        "clash",
        "wintun",
        "meta tun",
        "sing-box"
    ];

    public async Task<ProxySnapshot> ProbeAsync(AppConfig config, CancellationToken cancellationToken = default)
    {
        var coreCount = CountProxyCores();
        var portOpenTask = CanConnectAsync(config.MixedHost, config.MixedPort, config.TimeoutSeconds, cancellationToken);
        var tunTask = DetectTunAsync(cancellationToken);
        var systemProxy = IsSystemProxyEnabled();

        await Task.WhenAll(portOpenTask, tunTask);
        var portOpen = await portOpenTask;
        var tunDetected = await tunTask;
        var routeActive = systemProxy || tunDetected;

        var core = coreCount switch
        {
            0 => new MetricSnapshot("代理核心", "未运行", "未发现 Mihomo 进程", "核", HealthLevel.Error),
            1 => new MetricSnapshot("代理核心", "运行中", "检测到一个核心进程", "核", HealthLevel.Ok),
            _ => new MetricSnapshot("代理核心", $"{coreCount} 个进程", "可能存在双核心冲突", "核", HealthLevel.Warning)
        };

        var port = portOpen
            ? new MetricSnapshot("本地端口", $"{config.MixedPort} 监听中", config.MixedHost, "端", HealthLevel.Ok)
            : new MetricSnapshot("本地端口", $"{config.MixedPort} 未监听", "检查客户端端口设置", "端", HealthLevel.Error);

        MetricSnapshot route;
        if (tunDetected)
        {
            route = new MetricSnapshot("流量入口", "TUN 已接管", "检测到活动的隧道适配器", "路", HealthLevel.Ok);
        }
        else if (systemProxy)
        {
            route = new MetricSnapshot("流量入口", "系统代理已启用", "Windows 代理入口生效", "路", HealthLevel.Ok);
        }
        else
        {
            route = new MetricSnapshot("流量入口", "尚未接管", "系统代理与 TUN 均未检测到", "路", HealthLevel.Warning);
        }

        if (coreCount == 1 && portOpen && routeActive)
        {
            return new ProxySnapshot(
                "代理已接管",
                "本地入口与代理核心工作正常",
                HealthLevel.Ok,
                core,
                port,
                route,
                systemProxy,
                tunDetected);
        }

        if (coreCount > 1)
        {
            return new ProxySnapshot(
                "检测到状态冲突",
                "多个代理核心可能同时接管流量",
                HealthLevel.Warning,
                core,
                port,
                route,
                systemProxy,
                tunDetected);
        }

        return new ProxySnapshot(
            "代理未完整生效",
            "运行健康检查可查看具体原因",
            HealthLevel.Error,
            core,
            port,
            route,
            systemProxy,
            tunDetected);
    }

    public int CountProxyCores()
    {
        var count = 0;
        foreach (var processName in CoreProcessNames)
        {
            Process[] processes = [];
            try
            {
                processes = Process.GetProcessesByName(processName);
                count += processes.Length;
            }
            catch
            {
                // A protected process can disappear between enumeration calls.
            }
            finally
            {
                foreach (var process in processes)
                {
                    process.Dispose();
                }
            }
        }

        return count;
    }

    public async Task<bool> CanConnectAsync(
        string host,
        int port,
        int timeoutSeconds,
        CancellationToken cancellationToken = default)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 30)));
            using var client = new TcpClient();
            await client.ConnectAsync(host, port, timeout.Token);
            return client.Connected;
        }
        catch
        {
            return false;
        }
    }

    public bool IsSystemProxyEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            return Convert.ToInt32(key?.GetValue("ProxyEnable") ?? 0) == 1;
        }
        catch
        {
            return false;
        }
    }

    public async Task<bool> DetectTunAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var adapterFound = NetworkInterface.GetAllNetworkInterfaces().Any(adapter =>
                adapter.OperationalStatus == OperationalStatus.Up &&
                adapter.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                TunKeywords.Any(keyword =>
                    adapter.Name.Contains(keyword, StringComparison.OrdinalIgnoreCase) ||
                    adapter.Description.Contains(keyword, StringComparison.OrdinalIgnoreCase)));

            if (adapterFound)
            {
                return true;
            }
        }
        catch
        {
            // Fall through to the routing-table probe.
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "route.exe",
                    Arguments = "print 198.18.0.0",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                }
            };
            process.Start();
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var output = await outputTask;
            return process.ExitCode == 0 && output.Contains("198.18.", StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }
}
