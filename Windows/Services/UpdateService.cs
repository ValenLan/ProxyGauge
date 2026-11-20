using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProxyGauge.Services;

public sealed record UpdateRelease(
    string Version,
    string ReleaseNotes,
    Uri InstallerUri,
    Uri ChecksumUri,
    string InstallerName);

public sealed record DownloadedUpdate(UpdateRelease Release, string InstallerPath);

public sealed class UpdateService : IDisposable
{
    private static readonly Uri LatestReleaseUri = new(
        "https://api.github.com/repos/ValenLan/ProxyGauge/releases/latest");
    private readonly HttpClient _client;
    private readonly bool _ownsClient;

    public UpdateService(HttpClient? client = null)
    {
        _client = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        _ownsClient = client is null;
        _client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        _client.DefaultRequestHeaders.UserAgent.ParseAdd("ProxyGauge-Updater");
        _client.DefaultRequestHeaders.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
    }

    public static string CurrentVersion
    {
        get
        {
            var version = Assembly.GetEntryAssembly()?.GetName().Version;
            return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
        }
    }

    public async Task<UpdateRelease?> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var response = await _client.GetAsync(LatestReleaseUri, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        var root = document.RootElement;
        if (root.GetProperty("draft").GetBoolean() ||
            root.GetProperty("prerelease").GetBoolean())
        {
            throw new InvalidDataException("GitHub 返回的版本不是正式版。");
        }

        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!tag.StartsWith('v') || !IsValidVersion(tag[1..]))
        {
            throw new InvalidDataException("GitHub 返回的版本号无效。");
        }
        var version = tag[1..];
        if (CompareVersions(version, CurrentVersion) <= 0)
        {
            return null;
        }

        var runtime = RuntimeInformation.OSArchitecture switch
        {
            Architecture.X64 => "win-x64",
            Architecture.Arm64 => "win-arm64",
            _ => throw new PlatformNotSupportedException("ProxyGauge 更新器只支持 Windows x64 与 arm64。")
        };
        var installerName = $"ProxyGauge-{version}-{runtime}.msi";
        Uri? installerUri = null;
        Uri? checksumUri = null;
        foreach (var asset in root.GetProperty("assets").EnumerateArray())
        {
            var name = asset.GetProperty("name").GetString();
            var url = asset.GetProperty("browser_download_url").GetString();
            if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed)) continue;
            if (name == installerName) installerUri = parsed;
            if (name == "SHA256SUMS.txt") checksumUri = parsed;
        }
        if (installerUri is null || checksumUri is null)
        {
            throw new InvalidDataException($"最新 Release 缺少 {installerName} 或 SHA256SUMS.txt。");
        }

        return new UpdateRelease(
            version,
            root.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "",
            installerUri,
            checksumUri,
            installerName);
    }

    public async Task<DownloadedUpdate> DownloadAsync(
        UpdateRelease release,
        CancellationToken cancellationToken = default)
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ProxyGauge",
            "Updates",
            release.Version);
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        Directory.CreateDirectory(directory);
        var installerPath = Path.Combine(directory, release.InstallerName);

        using (var response = await _client.GetAsync(
            release.InstallerUri,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken))
        {
            response.EnsureSuccessStatusCode();
            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var destination = new FileStream(
                installerPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                81920,
                useAsync: true);
            await source.CopyToAsync(destination, cancellationToken);
        }

        var checksumText = await _client.GetStringAsync(release.ChecksumUri, cancellationToken);
        var expected = FindChecksum(checksumText, release.InstallerName)
            ?? throw new InvalidDataException("SHA256SUMS.txt 中没有当前 MSI 的校验值。");
        await using var installer = File.OpenRead(installerPath);
        var actual = Convert.ToHexString(await SHA256.HashDataAsync(installer, cancellationToken))
            .ToLowerInvariant();
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            File.Delete(installerPath);
            throw new InvalidDataException("更新包 SHA-256 校验失败，安装已停止。");
        }
        return new DownloadedUpdate(release, installerPath);
    }

    public static Process LaunchInstaller(DownloadedUpdate update) =>
        Process.Start(new ProcessStartInfo
        {
            FileName = "msiexec.exe",
            Arguments = $"/i \"{update.InstallerPath}\" /passive /norestart",
            UseShellExecute = true,
            Verb = "runas"
        }) ?? throw new InvalidOperationException("Windows Installer 没有启动。");

    public static int CompareVersions(string first, string second)
    {
        var lhs = ParseVersion(first);
        var rhs = ParseVersion(second);
        for (var index = 0; index < 3; index++)
        {
            var comparison = lhs[index].CompareTo(rhs[index]);
            if (comparison != 0) return comparison;
        }
        return 0;
    }

    public static string? FindChecksum(string text, string assetName)
    {
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var match = Regex.Match(line, "^([0-9A-Fa-f]{64})\\s+\\*?(.+?)\\s*$");
            if (match.Success && string.Equals(match.Groups[2].Value, assetName, StringComparison.Ordinal))
            {
                return match.Groups[1].Value.ToLowerInvariant();
            }
        }
        return null;
    }

    public void Dispose()
    {
        if (_ownsClient) _client.Dispose();
    }

    private static bool IsValidVersion(string value) =>
        Regex.IsMatch(value, "^[0-9]+\\.[0-9]+\\.[0-9]+$");

    private static int[] ParseVersion(string value)
    {
        if (!IsValidVersion(value)) throw new ArgumentException("版本号格式无效。", nameof(value));
        return value.Split('.').Select(int.Parse).ToArray();
    }
}
