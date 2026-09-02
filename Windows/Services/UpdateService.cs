using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProxyGauge.Services;

public sealed record UpdateRelease(
    string Version,
    string ReleaseNotes,
    Uri InstallerUri,
    Uri ChecksumUri,
    string InstallerName);

public sealed record DownloadedUpdate(
    UpdateRelease Release,
    string InstallerPath,
    string ExpectedSha256,
    long InstallerLength);

internal sealed record InstallerLaunchPlan(
    ProcessStartInfo StartInfo,
    string ReadyPath);

public sealed class UpdateService : IDisposable
{
    private const string Repository = "ValenLan/ProxyGauge";
    private const int MetadataTimeoutSeconds = 30;
    private const int ChecksumTimeoutSeconds = 60;
    private const int DownloadTimeoutSeconds = 600;
    private const int ElevationPreparationTimeoutSeconds = 120;
    internal const long MaximumMetadataBytes = 2L * 1024 * 1024;
    internal const long MaximumChecksumBytes = 1024 * 1024;
    internal const long MaximumInstallerBytes = 512L * 1024 * 1024;
    internal const int MaximumElevationCommandLength = 8000;
    internal const int InstallerTimeoutMilliseconds = 30 * 60 * 1000;

    private static readonly Uri LatestReleaseUri = new(
        $"https://api.github.com/repos/{Repository}/releases/latest");

    private static readonly HashSet<string> AllowedDownloadHosts = new(
        StringComparer.OrdinalIgnoreCase)
    {
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com"
    };

    private static readonly string[] DangerousEnvironmentVariables =
    [
        "COR_ENABLE_PROFILING",
        "COR_PROFILER",
        "COR_PROFILER_PATH",
        "COR_PROFILER_PATH_32",
        "COR_PROFILER_PATH_64",
        "CORECLR_ENABLE_PROFILING",
        "CORECLR_PROFILER",
        "CORECLR_PROFILER_PATH",
        "CORECLR_PROFILER_PATH_32",
        "CORECLR_PROFILER_PATH_64",
        "DOTNET_STARTUP_HOOKS",
        "DOTNET_ADDITIONAL_DEPS",
        "DOTNET_SHARED_STORE",
        "APPDOMAIN_MANAGER_ASM",
        "APPDOMAIN_MANAGER_TYPE",
        "COMPLUS_ApplicationMigrationRuntimeActivationConfigPath",
        "COMPLUS_InstallRoot",
        "COMPLUS_DefaultVersion",
        "COMPLUS_OnlyUseLatestCLR",
        "COMPLUS_Version",
        "DEVPATH",
        "PSModulePath",
        "PSExecutionPolicyPreference"
    ];

    private readonly HttpClient _client;
    private readonly bool _ownsClient;

    public UpdateService(HttpClient? client = null)
    {
        _client = client ?? new HttpClient(new HttpClientHandler
        {
            AllowAutoRedirect = false
        }) { Timeout = Timeout.InfiniteTimeSpan };
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
            var version = typeof(UpdateService).Assembly.GetName().Version;
            return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
        }
    }

    public async Task<UpdateRelease?> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var budget = CreateBudget(cancellationToken, TimeSpan.FromSeconds(MetadataTimeoutSeconds));
        using var response = await _client.GetAsync(
            LatestReleaseUri,
            HttpCompletionOption.ResponseHeadersRead,
            budget.Token);
        EnsureExactResponseUri(response, LatestReleaseUri, "GitHub Release API");
        response.EnsureSuccessStatusCode();
        var payload = await ReadBoundedBytesAsync(
            response.Content,
            MaximumMetadataBytes,
            budget.Token);
        using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 32 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("draft", out var draft) ||
            !root.TryGetProperty("prerelease", out var prerelease) ||
            (draft.ValueKind != JsonValueKind.True &&
             draft.ValueKind != JsonValueKind.False) ||
            (prerelease.ValueKind != JsonValueKind.True &&
             prerelease.ValueKind != JsonValueKind.False) ||
            draft.GetBoolean() || prerelease.GetBoolean())
        {
            throw new InvalidDataException("GitHub 返回的版本不是正式版。");
        }

        if (!root.TryGetProperty("tag_name", out var tagElement) ||
            tagElement.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException("GitHub 返回的版本号无效。");
        }
        var tag = tagElement.GetString() ?? "";
        if (!tag.StartsWith('v') || !IsValidVersion(tag[1..]))
        {
            throw new InvalidDataException("GitHub 返回的版本号无效。");
        }
        var version = tag[1..];
        if (CompareVersions(version, CurrentVersion) <= 0)
        {
            return null;
        }

        var installerName = $"ProxyGauge-{version}-{GetRuntimeIdentifier()}.msi";
        var installerUri = ReadUniqueReleaseAsset(root, version, installerName);
        var checksumUri = ReadUniqueReleaseAsset(root, version, "SHA256SUMS.txt");
        var releaseNotes = root.TryGetProperty("body", out var body) &&
            body.ValueKind == JsonValueKind.String
                ? body.GetString() ?? ""
                : "";

        return new UpdateRelease(
            version,
            releaseNotes,
            installerUri,
            checksumUri,
            installerName);
    }

    public async Task<DownloadedUpdate> DownloadAsync(
        UpdateRelease release,
        CancellationToken cancellationToken = default)
    {
        ValidateRelease(release);
        using var totalBudget = CreateBudget(
            cancellationToken,
            TimeSpan.FromSeconds(DownloadTimeoutSeconds));

        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new InvalidOperationException("无法定位当前用户的本地应用数据目录。");
        }
        var updatesRoot = Path.Combine(localApplicationData, "ProxyGauge", "Updates");
        Directory.CreateDirectory(updatesRoot);
        var directory = Path.Combine(updatesRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var installerPath = Path.Combine(directory, release.InstallerName);

        try
        {
            string checksumText;
            using (var checksumBudget = CreateBudget(
                       totalBudget.Token,
                       TimeSpan.FromSeconds(ChecksumTimeoutSeconds)))
            using (var response = await GetTrustedDownloadResponseAsync(
                       release.ChecksumUri,
                       checksumBudget.Token))
            {
                EnsureAllowedDownloadResponseUri(response, "SHA256SUMS.txt");
                response.EnsureSuccessStatusCode();
                var checksumBytes = await ReadBoundedBytesAsync(
                    response.Content,
                    MaximumChecksumBytes,
                    checksumBudget.Token);
                checksumText = new UTF8Encoding(false, true).GetString(checksumBytes);
            }

            var expected = FindChecksum(checksumText, release.InstallerName)
                ?? throw new InvalidDataException("SHA256SUMS.txt 中没有当前 MSI 的校验值。");

            long installerLength;
            using (var installerBudget = CreateBudget(
                       totalBudget.Token,
                       TimeSpan.FromSeconds(DownloadTimeoutSeconds)))
            {
                installerLength = await DownloadFileAsync(
                    release.InstallerUri,
                    installerPath,
                    MaximumInstallerBytes,
                    installerBudget.Token);
            }

            await using var installer = new FileStream(
                installerPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                81920,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var actual = Convert.ToHexString(
                    await SHA256.HashDataAsync(installer, totalBudget.Token))
                .ToLowerInvariant();
            if (!string.Equals(actual, expected, StringComparison.Ordinal))
            {
                throw new InvalidDataException("更新包 SHA-256 校验失败，安装已停止。");
            }
            totalBudget.Token.ThrowIfCancellationRequested();

            return new DownloadedUpdate(
                release,
                installerPath,
                expected,
                installerLength);
        }
        catch
        {
            TryDeleteDownloadedArtifacts(installerPath, directory);
            throw;
        }
    }

    public static Process LaunchInstaller(DownloadedUpdate update)
    {
        ValidateDownloadedUpdate(update);
        InstallerLaunchPlan plan;
        try
        {
            plan = CreateInstallerLaunchPlan(
                update,
                Guid.NewGuid().ToString("N"),
                Environment.ProcessId);
        }
        catch
        {
            TryDeleteDownloadedArtifacts(
                update.InstallerPath,
                Path.GetDirectoryName(update.InstallerPath)!);
            throw;
        }
        Process process;
        try
        {
            process = Process.Start(plan.StartInfo)
                ?? throw new InvalidOperationException("Windows 安装授权进程没有启动。");
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            TryDeleteDownloadedArtifacts(
                update.InstallerPath,
                Path.GetDirectoryName(update.InstallerPath)!);
            throw new InvalidOperationException("管理员授权已取消，更新没有安装。", exception);
        }
        catch
        {
            TryDeleteDownloadedArtifacts(
                update.InstallerPath,
                Path.GetDirectoryName(update.InstallerPath)!);
            throw;
        }

        var deadline = DateTime.UtcNow.AddSeconds(ElevationPreparationTimeoutSeconds);
        try
        {
            while (DateTime.UtcNow < deadline)
            {
                long? readyLength = null;
                FileAttributes? readyAttributes = null;
                string? readyValue = null;
                try
                {
                    if (File.Exists(plan.ReadyPath))
                    {
                        var readyInfo = new FileInfo(plan.ReadyPath);
                        readyLength = readyInfo.Length;
                        readyAttributes = readyInfo.Attributes;
                        readyValue = File.ReadAllText(plan.ReadyPath, Encoding.ASCII);
                    }
                }
                catch (IOException)
                {
                    // The elevated process may still be closing its protected readiness file.
                }
                catch (UnauthorizedAccessException)
                {
                    // Retry briefly while inherited Program Files ACLs settle.
                }

                if (readyLength.HasValue && readyAttributes.HasValue && readyValue is not null)
                {
                    if (readyLength.Value != 64 ||
                        (readyAttributes.Value & FileAttributes.ReparsePoint) != 0 ||
                        !string.Equals(
                            readyValue,
                            update.ExpectedSha256,
                            StringComparison.Ordinal))
                    {
                        throw new InvalidDataException(
                            "管理员进程没有确认受保护更新包的 SHA-256。");
                    }
                    if (process.HasExited)
                    {
                        throw new InvalidOperationException(
                            $"管理员进程在安装前退出，退出代码：{process.ExitCode}。");
                    }
                    TryDeleteDownloadedArtifacts(
                        update.InstallerPath,
                        Path.GetDirectoryName(update.InstallerPath)!);
                    return process;
                }

                if (process.WaitForExit(100))
                {
                    throw new InvalidOperationException(
                        $"更新安装准备失败，退出代码：{process.ExitCode}；受保护目录复制或 SHA-256 复核未完成。");
                }
            }
            throw new TimeoutException(
                $"等待管理员进程复核更新包超过 {ElevationPreparationTimeoutSeconds} 秒，更新没有启动。");
        }
        catch
        {
            process.Dispose();
            TryDeleteDownloadedArtifacts(
                update.InstallerPath,
                Path.GetDirectoryName(update.InstallerPath)!);
            throw;
        }
    }

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
        string? selected = null;
        foreach (var line in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var match = Regex.Match(line, "^([0-9A-Fa-f]{64})\\s+\\*?(.+?)\\s*$");
            if (!match.Success ||
                !string.Equals(match.Groups[2].Value, assetName, StringComparison.Ordinal))
            {
                continue;
            }
            if (selected is not null)
            {
                throw new InvalidDataException("SHA256SUMS.txt 含重复安装包校验值。");
            }
            selected = match.Groups[1].Value.ToLowerInvariant();
        }
        return selected;
    }

    internal static bool IsExactReleaseAssetUri(Uri candidate, string version, string assetName)
    {
        if (!IsValidVersion(version) ||
            string.IsNullOrWhiteSpace(assetName) ||
            assetName.IndexOfAny([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]) >= 0)
        {
            return false;
        }
        var expected = ExpectedReleaseAssetUri(version, assetName);
        return string.Equals(candidate.AbsoluteUri, expected.AbsoluteUri, StringComparison.Ordinal);
    }

    internal static bool IsAllowedDownloadResponseUri(Uri candidate) =>
        string.Equals(candidate.Scheme, Uri.UriSchemeHttps, StringComparison.Ordinal) &&
        candidate.IsDefaultPort &&
        string.IsNullOrEmpty(candidate.UserInfo) &&
        AllowedDownloadHosts.Contains(candidate.Host);

    internal static bool IsSuccessfulInstallerExitCode(int exitCode) =>
        exitCode is 0 or 1641 or 3010;

    internal static string GetRuntimeIdentifier() => RuntimeInformation.OSArchitecture switch
    {
        Architecture.X64 => "win-x64",
        Architecture.Arm64 => "win-arm64",
        _ => throw new PlatformNotSupportedException(
            "ProxyGauge 更新器只支持 Windows x64 与 arm64。")
    };

    internal static ProcessStartInfo CreateInstallerStartInfo(DownloadedUpdate update)
        => CreateInstallerLaunchPlan(
            update,
            Guid.NewGuid().ToString("N"),
            Environment.ProcessId).StartInfo;

    internal static InstallerLaunchPlan CreateInstallerLaunchPlan(
        DownloadedUpdate update,
        string secureToken,
        int parentProcessId)
    {
        ValidateDownloadedUpdateRecord(update);
        if (!Regex.IsMatch(secureToken, "^[0-9a-f]{32}$") || parentProcessId <= 0)
        {
            throw new InvalidDataException("提权安装握手参数无效。");
        }
        var systemDirectory = Environment.SystemDirectory;
        if (string.IsNullOrWhiteSpace(systemDirectory))
        {
            throw new InvalidOperationException("无法定位受保护的 Windows 系统目录。");
        }
        var cmdPath = Path.Combine(systemDirectory, "cmd.exe");
        var powershellPath = Path.Combine(
            systemDirectory,
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(cmdPath) || !File.Exists(powershellPath))
        {
            throw new InvalidOperationException("无法定位受保护的 Windows 安装启动程序。");
        }

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles))
        {
            throw new InvalidOperationException("无法定位受保护的 Program Files。");
        }
        var secureDirectory = Path.Combine(programFiles, $"ProxyGauge Update {secureToken}");
        var readyPath = Path.Combine(secureDirectory, "ready.sha256");
        var script = BuildElevatedInstallerScript(
            update,
            secureToken,
            parentProcessId);
        var encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var clearEnvironment = string.Join(
            " & ",
            DangerousEnvironmentVariables.Select(name => $"set \"{name}=\""));
        var arguments = $"/d /s /c {clearEnvironment} & \"{powershellPath}\" " +
            $"-NoLogo -NoProfile -NonInteractive -EncodedCommand {encodedScript}";
        if (arguments.Length > MaximumElevationCommandLength)
        {
            throw new InvalidOperationException(
                "提权安装命令超过 cmd.exe 的安全长度限制，更新没有启动。");
        }

        return new InstallerLaunchPlan(
            new ProcessStartInfo
            {
                FileName = cmdPath,
                Arguments = arguments,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            },
            readyPath);
    }

    internal static string BuildElevatedInstallerScript(DownloadedUpdate update)
        => BuildElevatedInstallerScript(
            update,
            "0123456789abcdef0123456789abcdef",
            1);

    internal static string BuildElevatedInstallerScript(
        DownloadedUpdate update,
        string secureToken,
        int parentProcessId)
    {
        ValidateDownloadedUpdateRecord(update);
        if (!Regex.IsMatch(secureToken, "^[0-9a-f]{32}$") || parentProcessId <= 0)
        {
            throw new InvalidDataException("提权安装握手参数无效。");
        }
        var source = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(Path.GetFullPath(update.InstallerPath)));
        return ElevatedInstallerScriptTemplate
            .Replace("__SOURCE_MSI_UTF8__", source, StringComparison.Ordinal)
            .Replace("__EXPECTED_SHA256__", update.ExpectedSha256, StringComparison.Ordinal)
            .Replace(
                "__EXPECTED_LENGTH__",
                update.InstallerLength.ToString(CultureInfo.InvariantCulture),
                StringComparison.Ordinal)
            .Replace("__SECURE_TOKEN__", secureToken, StringComparison.Ordinal)
            .Replace(
                "__PARENT_PROCESS_ID__",
                parentProcessId.ToString(CultureInfo.InvariantCulture),
                StringComparison.Ordinal)
            .Replace(
                "__INSTALLER_TIMEOUT_MILLISECONDS__",
                InstallerTimeoutMilliseconds.ToString(CultureInfo.InvariantCulture),
                StringComparison.Ordinal);
    }

    public void Dispose()
    {
        if (_ownsClient) _client.Dispose();
    }

    private static async Task<byte[]> ReadBoundedBytesAsync(
        HttpContent content,
        long maximumBytes,
        CancellationToken cancellationToken)
    {
        var declaredLength = content.Headers.ContentLength;
        if (declaredLength.HasValue && declaredLength.Value > maximumBytes)
        {
            throw new InvalidDataException("正式版响应超过安全大小限制。");
        }

        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        await using var destination = new MemoryStream();
        var buffer = new byte[81920];
        long total = 0;
        while (true)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken);
            if (read == 0) break;
            total += read;
            if (total > maximumBytes)
            {
                throw new InvalidDataException("正式版响应超过安全大小限制。");
            }
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
        if (total == 0)
        {
            throw new InvalidDataException("正式版响应为空。");
        }
        return destination.ToArray();
    }

    private async Task<long> DownloadFileAsync(
        Uri sourceUri,
        string destinationPath,
        long maximumBytes,
        CancellationToken cancellationToken)
    {
        using var response = await GetTrustedDownloadResponseAsync(
            sourceUri,
            cancellationToken);
        EnsureAllowedDownloadResponseUri(response, Path.GetFileName(destinationPath));
        response.EnsureSuccessStatusCode();
        var declaredLength = response.Content.Headers.ContentLength;
        if (declaredLength.HasValue && declaredLength.Value > maximumBytes)
        {
            throw new InvalidDataException("正式版响应超过安全大小限制。");
        }

        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
        await using var destination = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            81920,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var buffer = new byte[81920];
        long total = 0;
        while (true)
        {
            var read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken);
            if (read == 0) break;
            total += read;
            if (total > maximumBytes)
            {
                throw new InvalidDataException("正式版响应超过安全大小限制。");
            }
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
        if (total == 0)
        {
            throw new InvalidDataException("正式版响应为空。");
        }
        await destination.FlushAsync(cancellationToken);
        return total;
    }

    private async Task<HttpResponseMessage> GetTrustedDownloadResponseAsync(
        Uri initialUri,
        CancellationToken cancellationToken)
    {
        var currentUri = initialUri;
        for (var redirectCount = 0; redirectCount <= 5; redirectCount++)
        {
            if (!IsAllowedDownloadResponseUri(currentUri))
            {
                throw new InvalidDataException("正式版下载重定向到不受信任的地址。");
            }
            var response = await _client.GetAsync(
                currentUri,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            try
            {
                EnsureExactResponseUri(response, currentUri, "正式版下载");
            }
            catch
            {
                response.Dispose();
                throw;
            }
            var status = (int)response.StatusCode;
            if (status is not (301 or 302 or 303 or 307 or 308))
            {
                return response;
            }

            try
            {
                if (redirectCount == 5 || response.Headers.Location is null)
                {
                    throw new InvalidDataException("正式版下载重定向次数过多或缺少地址。");
                }
                currentUri = response.Headers.Location.IsAbsoluteUri
                    ? response.Headers.Location
                    : new Uri(currentUri, response.Headers.Location);
                if (!IsAllowedDownloadResponseUri(currentUri))
                {
                    throw new InvalidDataException("正式版下载重定向到不受信任的地址。");
                }
            }
            finally
            {
                response.Dispose();
            }
        }
        throw new InvalidDataException("正式版下载重定向次数过多。");
    }

    private static Uri ReadUniqueReleaseAsset(
        JsonElement root,
        string version,
        string assetName)
    {
        if (!root.TryGetProperty("assets", out var assets) ||
            assets.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("GitHub Release 缺少资源列表。");
        }

        Uri? selected = null;
        var matches = 0;
        foreach (var asset in assets.EnumerateArray())
        {
            if (asset.ValueKind != JsonValueKind.Object ||
                !asset.TryGetProperty("name", out var nameElement) ||
                nameElement.ValueKind != JsonValueKind.String ||
                !string.Equals(nameElement.GetString(), assetName, StringComparison.Ordinal))
            {
                continue;
            }
            matches++;
            if (!asset.TryGetProperty("browser_download_url", out var urlElement) ||
                urlElement.ValueKind != JsonValueKind.String ||
                !Uri.TryCreate(urlElement.GetString(), UriKind.Absolute, out var parsed) ||
                !IsExactReleaseAssetUri(parsed, version, assetName))
            {
                throw new InvalidDataException(
                    $"正式版 {assetName} 地址不属于指定的 GitHub Release。");
            }
            selected = parsed;
        }

        if (matches != 1 || selected is null)
        {
            throw new InvalidDataException($"最新 Release 缺少唯一的 {assetName}。");
        }
        return selected;
    }

    private static void ValidateRelease(UpdateRelease release)
    {
        if (!IsValidVersion(release.Version))
        {
            throw new InvalidDataException("更新版本号无效。");
        }
        var expectedInstallerName =
            $"ProxyGauge-{release.Version}-{GetRuntimeIdentifier()}.msi";
        if (!string.Equals(
                release.InstallerName,
                expectedInstallerName,
                StringComparison.Ordinal) ||
            !IsExactReleaseAssetUri(
                release.InstallerUri,
                release.Version,
                expectedInstallerName) ||
            !IsExactReleaseAssetUri(
                release.ChecksumUri,
                release.Version,
                "SHA256SUMS.txt"))
        {
            throw new InvalidDataException("更新资源名称或下载地址无效。");
        }
    }

    private static void ValidateDownloadedUpdateRecord(DownloadedUpdate update)
    {
        ValidateRelease(update.Release);
        if (!Regex.IsMatch(update.ExpectedSha256, "^[0-9a-f]{64}$") ||
            update.InstallerLength <= 0 ||
            update.InstallerLength > MaximumInstallerBytes ||
            string.IsNullOrWhiteSpace(update.InstallerPath) ||
            !Path.IsPathFullyQualified(update.InstallerPath) ||
            !string.Equals(
                Path.GetFileName(update.InstallerPath),
                update.Release.InstallerName,
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("已下载更新包的安装参数无效。");
        }
    }

    private static void ValidateDownloadedUpdate(DownloadedUpdate update)
    {
        ValidateDownloadedUpdateRecord(update);
        var fullPath = Path.GetFullPath(update.InstallerPath);
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        var expectedRoot = string.IsNullOrWhiteSpace(localApplicationData)
            ? ""
            : Path.GetFullPath(Path.Combine(localApplicationData, "ProxyGauge", "Updates"));
        var parent = Directory.GetParent(fullPath);
        if (parent?.Parent is null ||
            !Regex.IsMatch(parent.Name, "^[0-9a-f]{32}$") ||
            !string.Equals(parent.Parent.FullName, expectedRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("更新包不在 ProxyGauge 专用更新目录中。");
        }
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrWhiteSpace(root) || new DriveInfo(root).DriveType != DriveType.Fixed)
        {
            throw new InvalidDataException("更新包必须位于本机固定磁盘。");
        }
        var info = new FileInfo(fullPath);
        if (!info.Exists ||
            info.Length != update.InstallerLength ||
            (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new InvalidDataException("已下载更新包已移动、更改或不是常规本地文件。");
        }
        using var stream = new FileStream(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            81920,
            FileOptions.SequentialScan);
        var actual = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        if (!string.Equals(actual, update.ExpectedSha256, StringComparison.Ordinal))
        {
            throw new InvalidDataException("更新包在申请管理员授权前已发生变化。");
        }
    }

    private static Uri ExpectedReleaseAssetUri(string version, string assetName) =>
        new($"https://github.com/{Repository}/releases/download/v{version}/{assetName}");

    private static void EnsureExactResponseUri(
        HttpResponseMessage response,
        Uri expected,
        string resourceName)
    {
        var actual = response.RequestMessage?.RequestUri;
        if (actual is null ||
            !string.Equals(actual.AbsoluteUri, expected.AbsoluteUri, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"{resourceName} 重定向到非预期地址。");
        }
    }

    private static void EnsureAllowedDownloadResponseUri(
        HttpResponseMessage response,
        string resourceName)
    {
        var actual = response.RequestMessage?.RequestUri;
        if (actual is null || !IsAllowedDownloadResponseUri(actual))
        {
            throw new InvalidDataException($"{resourceName} 重定向到不受信任的地址。");
        }
    }

    private static CancellationTokenSource CreateBudget(
        CancellationToken cancellationToken,
        TimeSpan timeout)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        source.CancelAfter(timeout);
        return source;
    }

    private static void TryDeleteDownloadedArtifacts(string installerPath, string directory)
    {
        try
        {
            if (File.Exists(installerPath)) File.Delete(installerPath);
        }
        catch
        {
            // The verified installer never launches after a failed download; cleanup is best effort.
        }
        try
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: false);
        }
        catch
        {
            // Never recursively delete a user-writable directory that could have been raced.
        }
    }

    private static bool IsValidVersion(string value) =>
        TryParseVersion(value, out _);

    private static int[] ParseVersion(string value)
    {
        if (!TryParseVersion(value, out var parts))
        {
            throw new ArgumentException("版本号格式无效。", nameof(value));
        }
        return parts;
    }

    private static bool TryParseVersion(string? value, out int[] parts)
    {
        parts = [];
        if (string.IsNullOrWhiteSpace(value) ||
            !Regex.IsMatch(value, "^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        {
            return false;
        }
        var fields = value.Split('.');
        if (fields.Length != 3 || fields.Any(field =>
                !int.TryParse(
                    field,
                    NumberStyles.None,
                    CultureInfo.InvariantCulture,
                    out _)))
        {
            return false;
        }
        parts = fields.Select(field =>
            int.Parse(field, NumberStyles.None, CultureInfo.InvariantCulture)).ToArray();
        return true;
    }

    private const string ElevatedInstallerScriptTemplate = """
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$PSModuleAutoLoadingPreference='None'
function D($v){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v))}
$s=D('__SOURCE_MSI_UTF8__')
$h='__EXPECTED_SHA256__'
[long]$n=__EXPECTED_LENGTH__
$t='__SECURE_TOKEN__'
[int]$parent=__PARENT_PROCESS_ID__
$d=$null
$e=1603
try{
 if($h -notmatch '^[0-9a-f]{64}$' -or $t -notmatch '^[0-9a-f]{32}$' -or $parent -le 0 -or -not [IO.File]::Exists($s)){throw 'args'}
 $i=[IO.FileInfo]::new($s)
 if($n -le 0 -or $n -gt 536870912 -or $i.Length -ne $n){throw 'size'}
 $pf=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
 if([string]::IsNullOrWhiteSpace($pf)){throw 'programfiles'}
 $d=[IO.Path]::Combine($pf,'ProxyGauge Update '+$t)
 [void][IO.Directory]::CreateDirectory($d)
 if(([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'reparse'}
 $m=[IO.Path]::Combine($d,'ProxyGauge.msi')
 [IO.File]::Copy($s,$m,$false)
 $i=[IO.FileInfo]::new($m)
 if($i.Length -ne $n -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'copy'}
 $f=[IO.File]::OpenRead($m);$a=[Security.Cryptography.SHA256]::Create()
 try{$x=([BitConverter]::ToString($a.ComputeHash($f))).Replace('-','').ToLowerInvariant()}finally{$a.Dispose();$f.Dispose()}
 if($x -ne $h){throw 'hash'}
 $exe=[IO.Path]::Combine([Environment]::SystemDirectory,'msiexec.exe')
 if(-not [IO.File]::Exists($exe)){throw 'msiexec'}
 $q=$null
 $p=$null
 try{$q=[Diagnostics.Process]::GetProcessById($parent)}catch [ArgumentException]{}
 [IO.File]::WriteAllText([IO.Path]::Combine($d,'ready.sha256'),$h,[Text.Encoding]::ASCII)
 if($null -ne $q -and -not $q.WaitForExit(60000)){throw 'parent'}
 $si=[Diagnostics.ProcessStartInfo]::new()
 $si.FileName=$exe
 $si.Arguments='/i "'+$m+'" /passive /norestart'
 $si.UseShellExecute=$false
 $si.CreateNoWindow=$true
 $p=[Diagnostics.Process]::Start($si)
 if(-not $p.WaitForExit(__INSTALLER_TIMEOUT_MILLISECONDS__)){try{$p.Kill()}catch{};throw 'installer timeout'}
 $e=$p.ExitCode
}catch{$e=1603}finally{
 try{if($null -ne $p){$p.Dispose()}}catch{}
 try{if($null -ne $q){$q.Dispose()}}catch{}
 try{if($null -ne $d -and [IO.Directory]::Exists($d)){[IO.Directory]::Delete($d,$true)}}catch{}
}
exit $e
""";
}
