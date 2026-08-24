using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class PrivateBrowserService : IDisposable
{
    private readonly object _sync = new();
    private readonly Dictionary<int, (Process Process, string ProfileDirectory)> _active = [];

    public async Task<BrowserLaunchResult> LaunchAsync(
        string routeLabel,
        string host,
        int port,
        int timeoutSeconds,
        CancellationToken cancellationToken = default)
    {
        if (!LocalEndpointPolicy.IsLoopbackHost(host) || port is < 1 or > 65535)
        {
            return new BrowserLaunchResult(false, "隔离检测只允许使用本机回环代理。", RouteLabel: routeLabel);
        }

        var browser = FindBrowser();
        if (browser is null)
        {
            return new BrowserLaunchResult(
                false,
                "未找到 Google Chrome 或 Microsoft Edge。",
                RouteLabel: routeLabel);
        }

        var exitIp = await TryGetExitIpAsync(host, port, timeoutSeconds, cancellationToken);
        var urls = new List<string>
        {
            "https://browserleaks.com/ip",
            "https://iphey.com/",
            "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test"
        };
        if (IPAddress.TryParse(exitIp, out _))
        {
            urls.Add($"https://scamalytics.com/ip/{Uri.EscapeDataString(exitIp!)}");
            urls.Add($"https://www.abuseipdb.com/check/{Uri.EscapeDataString(exitIp!)}");
        }

        var profileDirectory = Path.Combine(
            Path.GetTempPath(),
            $"proxygauge-browser.{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(profileDirectory);
            var startInfo = new ProcessStartInfo
            {
                FileName = browser.Value.Path,
                UseShellExecute = false
            };
            startInfo.ArgumentList.Add($"--user-data-dir={profileDirectory}");
            startInfo.ArgumentList.Add(browser.Value.IsEdge ? "--inprivate" : "--incognito");
            startInfo.ArgumentList.Add("--no-first-run");
            startInfo.ArgumentList.Add("--no-default-browser-check");
            startInfo.ArgumentList.Add("--disable-extensions");
            startInfo.ArgumentList.Add("--disable-sync");
            startInfo.ArgumentList.Add("--disable-background-networking");
            startInfo.ArgumentList.Add("--disable-component-update");
            startInfo.ArgumentList.Add("--disable-session-crashed-bubble");
            var proxyUri = new UriBuilder(Uri.UriSchemeHttp, host.Trim('[', ']'), port).Uri;
            startInfo.ArgumentList.Add($"--proxy-server={proxyUri.GetLeftPart(UriPartial.Authority)}");
            startInfo.ArgumentList.Add("--new-window");
            foreach (var url in urls) startInfo.ArgumentList.Add(url);

            var process = Process.Start(startInfo);
            if (process is null)
            {
                SafeDeleteProfile(profileDirectory);
                return new BrowserLaunchResult(false, "浏览器没有成功启动。", browser.Value.Name, routeLabel);
            }

            process.EnableRaisingEvents = true;
            process.Exited += Browser_Exited;
            lock (_sync)
            {
                _active[process.Id] = (process, profileDirectory);
            }
            if (process.HasExited)
            {
                Cleanup(process.Id, terminate: false);
            }

            return new BrowserLaunchResult(
                true,
                $"已使用 {host}:{port} 打开隔离窗口；关闭窗口后会清理临时资料。",
                browser.Value.Name,
                routeLabel);
        }
        catch
        {
            SafeDeleteProfile(profileDirectory);
            return new BrowserLaunchResult(false, "隔离浏览器启动失败，请检查浏览器安装。", browser.Value.Name, routeLabel);
        }
    }

    public void Dispose()
    {
        int[] processIds;
        lock (_sync) processIds = _active.Keys.ToArray();
        foreach (var processId in processIds) Cleanup(processId, terminate: true);
    }

    private void Browser_Exited(object? sender, EventArgs e)
    {
        if (sender is Process process) Cleanup(process.Id, terminate: false);
    }

    private void Cleanup(int processId, bool terminate)
    {
        (Process Process, string ProfileDirectory) active;
        lock (_sync)
        {
            if (!_active.Remove(processId, out active)) return;
        }

        try
        {
            active.Process.Exited -= Browser_Exited;
            if (terminate && !active.Process.HasExited)
            {
                active.Process.Kill(entireProcessTree: true);
                active.Process.WaitForExit(2000);
            }
        }
        catch
        {
            // Cleanup still attempts the tightly scoped temporary profile path.
        }
        finally
        {
            active.Process.Dispose();
            SafeDeleteProfile(active.ProfileDirectory);
        }
    }

    private static async Task<string?> TryGetExitIpAsync(
        string host,
        int port,
        int timeoutSeconds,
        CancellationToken cancellationToken)
    {
        try
        {
            using var handler = new SocketsHttpHandler
            {
                Proxy = new WebProxy(new UriBuilder(Uri.UriSchemeHttp, host.Trim('[', ']'), port).Uri),
                UseProxy = true,
                ConnectTimeout = TimeSpan.FromSeconds(timeoutSeconds)
            };
            using var client = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(Math.Max(timeoutSeconds, 8))
            };
            var value = (await client.GetStringAsync("https://api.ipify.org", cancellationToken)).Trim();
            return IPAddress.TryParse(value, out _) ? value : null;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return null;
        }
    }

    private static (string Path, string Name, bool IsEdge)? FindBrowser()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new (string Path, string Name, bool IsEdge)[]
        {
            (Path.Combine(programFiles, "Google", "Chrome", "Application", "chrome.exe"), "Google Chrome", false),
            (Path.Combine(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"), "Google Chrome", false),
            (Path.Combine(localAppData, "Google", "Chrome", "Application", "chrome.exe"), "Google Chrome", false),
            (Path.Combine(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"), "Microsoft Edge", true),
            (Path.Combine(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"), "Microsoft Edge", true)
        };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate.Path)) return candidate;
        }
        return null;
    }

    private static void SafeDeleteProfile(string profileDirectory)
    {
        try
        {
            var tempRoot = Path.GetFullPath(Path.GetTempPath())
                .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var fullPath = Path.GetFullPath(profileDirectory);
            var leaf = Path.GetFileName(fullPath);
            if (!fullPath.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) ||
                !leaf.StartsWith("proxygauge-browser.", StringComparison.Ordinal) ||
                leaf.Length <= "proxygauge-browser.".Length)
            {
                return;
            }

            if (Directory.Exists(fullPath)) Directory.Delete(fullPath, recursive: true);
        }
        catch
        {
            // A locked Chromium file can be removed on a later app cleanup pass.
        }
    }
}
