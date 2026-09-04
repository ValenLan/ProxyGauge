using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ProxyGauge.Services;

public sealed record ProxyApplicationChoice(string Label, string ExecutablePath);

public static class ProxyApplicationSelection
{
    public const string DefaultLabel = "自动识别代理核心（Clash / Mihomo、iKuuu 等）";
    public const int MaximumPathLength = 1800;

    // MainModule requests VM_READ and hides LocalSystem VPN cores from a normal
    // desktop token. Reading the image name needs only limited query rights.
    internal static string? ReadProcessPath(int processId)
    {
        using var handle = OpenProcess(0x1000, false, processId);
        if (handle.IsInvalid) return null;
        var buffer = new StringBuilder(32768);
        var size = buffer.Capacity;
        return QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? buffer.ToString() : null;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags,
        StringBuilder name, ref int size);

    public static string NormalizePath(string? value)
    {
        if (value is null) throw new InvalidDataException("代理程序路径不能为 null。");
        var path = value.Trim();
        if (path.Length == 0) return string.Empty;
        if (path.Length > MaximumPathLength || path.Any(char.IsControl) ||
            path.Length < 7 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\' ||
            path[2..].IndexOfAny([':', '"', '<', '>', '|', '*', '?', '/']) >= 0 ||
            !path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
            path.Split('\\').Any(part => part is "." or ".."))
        {
            throw new InvalidDataException("请选择本机磁盘上的代理核心 .exe 文件，不能使用网络路径或命令行参数。");
        }
        return path;
    }

    public static IReadOnlyList<ProxyApplicationChoice> FindRunningApplications()
    {
        var paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var path = NormalizePath(ReadProcessPath(process.Id));
                    if (path.Length > 0) paths.TryAdd(path, process.ProcessName);
                }
                catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or
                    InvalidOperationException or InvalidDataException or NotSupportedException)
                {
                    // Protected/exited processes may be selected explicitly with the file picker.
                }
            }
        }
        return paths.OrderByDescending(pair => IsLikelyProxy(pair.Value))
            .ThenBy(pair => pair.Value, StringComparer.OrdinalIgnoreCase)
            .Select(pair => new ProxyApplicationChoice($"{pair.Value} — {pair.Key}", pair.Key))
            .ToArray();
    }

    public static async Task<IReadOnlyList<ProxyApplicationChoice>> FindRunningApplicationsAsync(
        CancellationToken cancellationToken = default)
    {
        var local = FindRunningApplications();
        IReadOnlyList<ProxyApplicationChoice> service = [];
        try { service = await new GuardClient().GetApplicationsAsync(cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) when (exception is IOException or TimeoutException or
            OperationCanceledException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or GuardCommandException)
        {
            // Older/offline services still support local discovery and the explicit file picker.
        }
        return service.Concat(local).DistinctBy(choice => choice.ExecutablePath, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(choice => IsLikelyCore(Path.GetFileNameWithoutExtension(choice.ExecutablePath)))
            .ThenByDescending(choice => IsLikelyProxy(Path.GetFileNameWithoutExtension(choice.ExecutablePath)))
            .ThenBy(choice => choice.Label, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static bool IsLikelyCore(string name) =>
        name.EndsWith("core", StringComparison.OrdinalIgnoreCase) ||
        new[] { "mihomo", "verge-mihomo", "clash", "clash-meta", "sing-box", "singbox", "xray", "v2ray" }
            .Contains(name, StringComparer.OrdinalIgnoreCase);

    private static bool IsLikelyProxy(string name) =>
        new[] { "clash", "mihomo", "ikuuu", "sing-box", "singbox", "vpn", "wireguard" }
            .Any(part => name.Contains(part, StringComparison.OrdinalIgnoreCase));
}
