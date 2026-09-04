using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Reflection;
using ProxyGauge;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

if (args.Length >= 2 && args[0] == "--runtime-probe")
{
    await RuntimeDiagnostics.RunAsync(args);
    return;
}
if (args.Length is 7 or 8 && args[0] == "--handover-probe")
{
    await GuardHandoverDiagnostics.RunAsync(args);
    return;
}

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static HealthCheckItem Item(HealthLevel level) => new("test", "test", level);

await GuardActivationAssertions.RunAsync();
await NetworkStateAssertions.RunAsync();

Require(GuardProtocol.CreateApplicationEnableRequest("") == "ENABLE_APP\tCLASH",
    "The default guard selection must resolve Clash/Mihomo, without a mixed-port prerequisite.");
const string chosenCore = @"E:\代理工具\iKuuuVPNCore.exe";
Require(GuardProtocol.ParseApplications($"OK\tAPPLICATIONS\t{chosenCore}\t{chosenCore}")
        is [{ ExecutablePath: chosenCore }],
    "Read-only Guard discovery must preserve a SYSTEM core's exact path and deduplicate it without granting a permit.");
var invalidApplicationResponseRejected = false;
try { GuardProtocol.ParseApplications("OK\tAPPLICATIONS\t\\\\host\\clash.exe"); }
catch (GuardCommandException) { invalidApplicationResponseRejected = true; }
Require(invalidApplicationResponseRejected, "Guard application discovery must reject nonlocal executable paths.");
Require(GuardProtocol.CreateApplicationEnableRequest($" {chosenCore} ") == $"ENABLE_APP\t{chosenCore}" &&
        new AppConfig { ProxyExecutablePath = chosenCore }.Clone().ProxyExecutablePath == chosenCore,
    "The exact selected executable must survive normalization, cloning, and the pipe protocol.");
foreach (var badPath in new string?[] { null, "clash.exe", @"\\host\share\clash.exe", @"C:\a.exe --help",
             "C:\\a.exe\tDISABLE", @"C:\a\..\b.exe", @"C:\a.exe:stream.exe", @"C:/a.exe" })
{
    var rejected = false;
    try { ProxyApplicationSelection.NormalizePath(badPath); }
    catch (InvalidDataException) { rejected = true; }
    Require(rejected, $"A proxy choice must reject remote paths, arguments, traversal, and protocol injection: {badPath}");
}

static HttpResponseMessage TextResponse(HttpStatusCode status, string content) => new(status)
{
    Content = new StringContent(content)
};

static ProxySnapshot TestSnapshot(int port) => new(
    "代理路径已确认",
    "test",
    HealthLevel.Ok,
    new MetricSnapshot("代理核心", "运行中", "test", "核", HealthLevel.Ok),
    new MetricSnapshot("本地端口", $"{port} 监听中", "127.0.0.1", "端", HealthLevel.Ok),
    new MetricSnapshot("系统代理", "已启用", "test", "入", HealthLevel.Ok),
    true,
    false);

static Color RequireSolidColor(Brush brush, string message)
{
    Require(brush is SolidColorBrush, message);
    return ((SolidColorBrush)brush).Color;
}

static byte[] RenderPixels(FrameworkElement element, int width, int height, string? artifactPath)
{
    element.Measure(new Size(width, height));
    element.Arrange(new Rect(0, 0, width, height));
    element.UpdateLayout();

    var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
    bitmap.Render(element);

    if (!string.IsNullOrWhiteSpace(artifactPath))
    {
        Directory.CreateDirectory(Path.GetDirectoryName(artifactPath)!);
        using var stream = File.Create(artifactPath);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(stream);
    }

    var pixels = new byte[width * height * 4];
    bitmap.CopyPixels(pixels, width * 4, 0);
    return pixels;
}

static int CountExactColor(byte[] pixels, Color color)
{
    var count = 0;
    for (var offset = 0; offset < pixels.Length; offset += 4)
    {
        if (pixels[offset] == color.B &&
            pixels[offset + 1] == color.G &&
            pixels[offset + 2] == color.R &&
            pixels[offset + 3] == color.A)
        {
            count++;
        }
    }
    return count;
}

static IEnumerable<DependencyObject> VisualDescendants(DependencyObject parent)
{
    for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
    {
        var child = VisualTreeHelper.GetChild(parent, index);
        yield return child;
        foreach (var descendant in VisualDescendants(child))
        {
            yield return descendant;
        }
    }
}

static double ContrastRatio(string first, string second)
{
    static double Luminance(string color)
    {
        var offset = color.Length == 9 ? 3 : 1;
        var channels = Enumerable.Range(0, 3)
            .Select(index => Convert.ToInt32(color.Substring(offset + (index * 2), 2), 16) / 255d)
            .Select(value => value <= 0.04045
                ? value / 12.92
                : Math.Pow((value + 0.055) / 1.055, 2.4))
            .ToArray();
        return (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2]);
    }

    var firstLuminance = Luminance(first);
    var secondLuminance = Luminance(second);
    return (Math.Max(firstLuminance, secondLuminance) + 0.05) /
        (Math.Min(firstLuminance, secondLuminance) + 0.05);
}

Require(ThemeService.ResolveTheme(false, "dark") == AppThemeKind.Dark,
    "A saved dark choice must select the dark palette.");
Require(ThemeService.ResolveTheme(false, "light") == AppThemeKind.Light,
    "A saved light choice must select the light palette.");
Require(ThemeService.ResolveTheme(false, null) == AppThemeKind.Light,
    "The first launch must use the light palette without following Windows.");
Require(ThemeService.ResolveTheme(true, "dark") == AppThemeKind.HighContrast,
    "High contrast must take priority over the manual appearance choice.");

var productAssembly = typeof(UpdateService).Assembly;
var productAssemblyVersion = productAssembly.GetName().Version
    ?? throw new InvalidOperationException("The product assembly must expose its version.");
var expectedProductVersion = $"{productAssemblyVersion.Major}.{productAssemblyVersion.Minor}.{productAssemblyVersion.Build}";
var entryAssembly = Assembly.GetEntryAssembly()
    ?? throw new InvalidOperationException("The test host must expose its entry assembly.");
var entryAssemblyVersion = entryAssembly.GetName().Version
    ?? throw new InvalidOperationException("The test host must expose its version.");
var expectedHostVersion = $"{entryAssemblyVersion.Major}.{entryAssemblyVersion.Minor}.{entryAssemblyVersion.Build}";
Require(!ReferenceEquals(productAssembly, entryAssembly) && expectedProductVersion != expectedHostVersion,
    "The updater regression must run in a host whose assembly and version differ from the product.");
Require(UpdateService.CurrentVersion == expectedProductVersion &&
        UpdateService.CurrentVersion != expectedHostVersion,
    "The updater must report the product assembly version, never its entry host version.");

var currentReleaseJson = $$"""
{
  "draft": false,
  "prerelease": false,
  "tag_name": "v{{expectedProductVersion}}",
  "assets": []
}
""";
using (var currentReleaseClient = new HttpClient(new StubHttpMessageHandler((_, _) =>
       Task.FromResult(TextResponse(HttpStatusCode.OK, currentReleaseJson)))))
using (var currentReleaseService = new UpdateService(currentReleaseClient))
{
    Require(await currentReleaseService.CheckAsync() is null,
        "A release matching the product version must not become an update because the host version differs.");
}

Require(UpdateService.CompareVersions("1.6.3", "1.6.2") > 0,
    "A newer semantic version must be detected.");
Require(UpdateService.CompareVersions("1.5.7", "1.5.7") == 0,
    "Equal semantic versions must not trigger an update.");
var checksum = new string('a', 64);
Require(UpdateService.FindChecksum($"{checksum}  ProxyGauge-1.6.3-win-x64.msi\n", "ProxyGauge-1.6.3-win-x64.msi") == checksum,
    "The updater must select the exact MSI checksum.");
var duplicateChecksumRejected = false;
try
{
    UpdateService.FindChecksum(
        $"{checksum}  ProxyGauge-1.6.3-win-x64.msi\n" +
        $"{new string('b', 64)}  ProxyGauge-1.6.3-win-x64.msi\n",
        "ProxyGauge-1.6.3-win-x64.msi");
}
catch (InvalidDataException)
{
    duplicateChecksumRejected = true;
}
Require(duplicateChecksumRejected,
    "Duplicate checksum entries for the selected MSI must fail closed.");

var updaterRuntime = UpdateService.GetRuntimeIdentifier();
var updaterVersion = "9999.0.0";
var updaterName = $"ProxyGauge-{updaterVersion}-{updaterRuntime}.msi";
var updaterBase = $"https://github.com/ValenLan/ProxyGauge/releases/download/v{updaterVersion}";
var updaterRelease = new UpdateRelease(
    updaterVersion,
    "",
    new Uri($"{updaterBase}/{updaterName}"),
    new Uri($"{updaterBase}/SHA256SUMS.txt"),
    updaterName);
Require(UpdateService.IsExactReleaseAssetUri(
        updaterRelease.InstallerUri,
        updaterVersion,
        updaterName) &&
        !UpdateService.IsExactReleaseAssetUri(
            new Uri($"https://example.com/{updaterName}"),
            updaterVersion,
            updaterName) &&
        !UpdateService.IsExactReleaseAssetUri(
            new Uri($"{updaterBase}/{updaterName}?unexpected=1"),
            updaterVersion,
            updaterName),
    "Release assets must use the exact repository, tag, name, and query-free GitHub URL.");
Require(UpdateService.IsAllowedDownloadResponseUri(
        new Uri("https://release-assets.githubusercontent.com/example")) &&
        !UpdateService.IsAllowedDownloadResponseUri(
            new Uri("http://release-assets.githubusercontent.com/example")) &&
        !UpdateService.IsAllowedDownloadResponseUri(
            new Uri("https://release-assets.githubusercontent.com.evil.example/example")),
    "Release redirects must remain HTTPS on an exact GitHub download host.");

var duplicateReleaseAssetRejected = false;
var duplicatedAssetJson = $$"""
{
  "draft": false,
  "prerelease": false,
  "tag_name": "v{{updaterVersion}}",
  "assets": [
    { "name": "{{updaterName}}", "browser_download_url": "{{updaterBase}}/{{updaterName}}" },
    { "name": "{{updaterName}}", "browser_download_url": "{{updaterBase}}/{{updaterName}}" },
    { "name": "SHA256SUMS.txt", "browser_download_url": "{{updaterBase}}/SHA256SUMS.txt" }
  ]
}
""";
using (var duplicateAssetClient = new HttpClient(new StubHttpMessageHandler((_, _) =>
       Task.FromResult(TextResponse(HttpStatusCode.OK, duplicatedAssetJson)))))
using (var duplicateAssetService = new UpdateService(duplicateAssetClient))
{
    try
    {
        await duplicateAssetService.CheckAsync();
    }
    catch (InvalidDataException)
    {
        duplicateReleaseAssetRejected = true;
    }
}
Require(duplicateReleaseAssetRejected,
    "A release with duplicate selected assets must fail closed.");

var oversizedChecksumRejected = false;
using (var oversizedUpdateClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           var response = TextResponse(HttpStatusCode.OK, "x");
           if (request.RequestUri!.AbsoluteUri.EndsWith("SHA256SUMS.txt", StringComparison.Ordinal))
           {
               response.Content.Headers.ContentLength = UpdateService.MaximumChecksumBytes + 1;
           }
           return Task.FromResult(response);
       })))
using (var oversizedUpdateService = new UpdateService(oversizedUpdateClient))
{
    try
    {
        await oversizedUpdateService.DownloadAsync(updaterRelease);
    }
    catch (InvalidDataException)
    {
        oversizedChecksumRejected = true;
    }
}
Require(oversizedChecksumRejected,
    "Updater downloads must reject a declared response above the checksum size limit.");

var untrustedRedirectRejected = false;
using (var redirectUpdateClient = new HttpClient(new StubHttpMessageHandler((_, _) =>
       {
           var response = new HttpResponseMessage(HttpStatusCode.Redirect);
           response.Headers.Location = new Uri("https://downloads.example.invalid/ProxyGauge.msi");
           return Task.FromResult(response);
       })))
using (var redirectUpdateService = new UpdateService(redirectUpdateClient))
{
    try
    {
        await redirectUpdateService.DownloadAsync(updaterRelease);
    }
    catch (InvalidDataException)
    {
        untrustedRedirectRejected = true;
    }
}
Require(untrustedRedirectRejected,
    "Every download redirect hop must stay on an exact HTTPS GitHub asset host.");

var updaterTestPath = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "ProxyGauge",
    "Updates",
    "0123456789abcdef0123456789abcdef",
    updaterName);
var downloadedUpdatePlan = new DownloadedUpdate(
    updaterRelease,
    updaterTestPath,
    checksum,
    1024);
var elevatedScript = UpdateService.BuildElevatedInstallerScript(downloadedUpdatePlan);
var powershellParserPath = Path.Combine(
    Environment.SystemDirectory,
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe");
var parserStartInfo = new System.Diagnostics.ProcessStartInfo
{
    FileName = powershellParserPath,
    UseShellExecute = false,
    CreateNoWindow = true,
    RedirectStandardInput = true,
    RedirectStandardError = true
};
parserStartInfo.ArgumentList.Add("-NoLogo");
parserStartInfo.ArgumentList.Add("-NoProfile");
parserStartInfo.ArgumentList.Add("-NonInteractive");
parserStartInfo.ArgumentList.Add("-Command");
parserStartInfo.ArgumentList.Add(
    "$source=[Console]::In.ReadToEnd();[void][ScriptBlock]::Create($source)");
foreach (var environmentName in new[]
         {
             "COR_ENABLE_PROFILING", "COR_PROFILER", "COR_PROFILER_PATH",
             "COR_PROFILER_PATH_32", "COR_PROFILER_PATH_64",
             "CORECLR_ENABLE_PROFILING", "CORECLR_PROFILER", "CORECLR_PROFILER_PATH",
             "CORECLR_PROFILER_PATH_32", "CORECLR_PROFILER_PATH_64",
             "DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE",
             "APPDOMAIN_MANAGER_ASM", "APPDOMAIN_MANAGER_TYPE",
             "COMPLUS_ApplicationMigrationRuntimeActivationConfigPath",
             "COMPLUS_InstallRoot", "COMPLUS_DefaultVersion", "COMPLUS_OnlyUseLatestCLR",
             "COMPLUS_Version", "DEVPATH"
         })
{
    parserStartInfo.Environment.Remove(environmentName);
}
using (var parserProcess = System.Diagnostics.Process.Start(parserStartInfo)
       ?? throw new InvalidOperationException("Windows PowerShell parser did not start."))
{
    var parserErrorTask = parserProcess.StandardError.ReadToEndAsync();
    await parserProcess.StandardInput.WriteAsync(elevatedScript);
    parserProcess.StandardInput.Close();
    using var parserTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    try
    {
        await parserProcess.WaitForExitAsync(parserTimeout.Token);
    }
    catch (OperationCanceledException)
    {
        parserProcess.Kill(entireProcessTree: true);
        throw new InvalidOperationException(
            "Windows PowerShell did not parse the elevated installer script within 15 seconds.");
    }
    var parserError = await parserErrorTask;
    Require(parserProcess.ExitCode == 0,
        $"The generated elevated installer script must parse in Windows PowerShell 5.1: {parserError}");
}
var launchPlan = UpdateService.CreateInstallerLaunchPlan(
    downloadedUpdatePlan,
    "fedcba9876543210fedcba9876543210",
    4321);
var installerStartInfo = launchPlan.StartInfo;
Require(installerStartInfo.UseShellExecute &&
        installerStartInfo.Verb == "runas" &&
        string.Equals(
            installerStartInfo.FileName,
            Path.Combine(Environment.SystemDirectory, "cmd.exe"),
            StringComparison.OrdinalIgnoreCase),
    "The updater must request UAC only through the protected System32 command processor.");
Require(launchPlan.ReadyPath.EndsWith(
        @"ProxyGauge Update fedcba9876543210fedcba9876543210\ready.sha256",
        StringComparison.OrdinalIgnoreCase),
    "The main process must wait for a root-protected hash readiness marker before exiting.");
Require(installerStartInfo.Arguments.Length <= UpdateService.MaximumElevationCommandLength &&
        installerStartInfo.Arguments.Contains("set \"COR_ENABLE_PROFILING=\"", StringComparison.Ordinal) &&
        installerStartInfo.Arguments.Contains("set \"CORECLR_ENABLE_PROFILING=\"", StringComparison.Ordinal) &&
        installerStartInfo.Arguments.Contains("set \"DOTNET_STARTUP_HOOKS=\"", StringComparison.Ordinal) &&
        installerStartInfo.Arguments.Contains("set \"APPDOMAIN_MANAGER_ASM=\"", StringComparison.Ordinal),
    "The bounded elevation command must clear .NET profiling and startup injection variables.");
Require(elevatedScript.Contains(
            "[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)",
            StringComparison.Ordinal) &&
        elevatedScript.Contains("[IO.File]::Copy($s,$m,$false)", StringComparison.Ordinal) &&
        elevatedScript.IndexOf("[IO.File]::Copy($s,$m,$false)", StringComparison.Ordinal) <
        elevatedScript.IndexOf("ComputeHash($f)", StringComparison.Ordinal) &&
        elevatedScript.Contains(
            "[IO.Path]::Combine([Environment]::SystemDirectory,'msiexec.exe')",
            StringComparison.Ordinal) &&
        elevatedScript.IndexOf("GetProcessById($parent)", StringComparison.Ordinal) <
        elevatedScript.IndexOf("ready.sha256", StringComparison.Ordinal) &&
        elevatedScript.IndexOf("ready.sha256", StringComparison.Ordinal) <
        elevatedScript.IndexOf("$q.WaitForExit(60000)", StringComparison.Ordinal) &&
        elevatedScript.IndexOf("$q.WaitForExit(60000)", StringComparison.Ordinal) <
        elevatedScript.IndexOf("[Diagnostics.Process]::Start($si)", StringComparison.Ordinal) &&
        elevatedScript.Contains(
            $"$p.WaitForExit({UpdateService.InstallerTimeoutMilliseconds})",
            StringComparison.Ordinal) &&
        elevatedScript.Contains("$p.Kill()", StringComparison.Ordinal) &&
        elevatedScript.Contains("$p.Dispose()", StringComparison.Ordinal) &&
        !elevatedScript.Contains("$p.WaitForExit()", StringComparison.Ordinal),
    "The elevated worker must re-hash in Program Files, signal readiness, wait for the app to exit, then run System32 msiexec with a bounded lifetime.");
Require(UpdateService.InstallerTimeoutMilliseconds == 30 * 60 * 1000,
    "The in-app Windows Installer lifetime must be bounded to 30 minutes.");
Require(MainWindow.CanStartAutomaticRefresh(false, true, true) &&
        !MainWindow.CanStartAutomaticRefresh(false, true, false) &&
        !MainWindow.CanStartAutomaticRefresh(false, false, true) &&
        !MainWindow.CanStartAutomaticRefresh(true, true, true),
    "Automatic Windows refreshes must run only while the main window is active and loaded.");
Require(UpdateService.IsSuccessfulInstallerExitCode(0) &&
        UpdateService.IsSuccessfulInstallerExitCode(1641) &&
        UpdateService.IsSuccessfulInstallerExitCode(3010) &&
        !UpdateService.IsSuccessfulInstallerExitCode(1603),
    "Only Windows Installer success and reboot-required codes may complete an update.");

var flatExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.8.8","city":"Los Angeles","region":"California","country":"US","country_name":"United States","version":"IPv6","type":"hosting","asn":"AS64500","org":"Example ASN"}""");
Require(flatExitSummary is not null, "The city lookup response must produce an exit summary.");
Require(flatExitSummary!.Location == "United States · California · Los Angeles",
    "The exit summary must display country, region, and city.");
Require(flatExitSummary.IpVersion == "IPv4",
    "A parsed IPv4 exit address must produce the local IPv4 label and ignore conflicting upstream metadata.");
var regionalExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"1.1.1.1","region":"California","country_name":"United States"}""");
Require(regionalExitSummary?.Location == "United States · California",
    "The region must be shown when a city is unavailable.");
var ipv6ExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"2606:4700:4700::1111","city":"Seattle","country_name":"United States"}""");
Require(ipv6ExitSummary?.IpVersion == "IPv6",
    "A parsed IPv6 exit address must produce the local IPv6 label.");
Require(ExitSummaryService.ParseResponse(
        """{"ip":"not-an-ip","city":"Seattle","country_name":"United States"}""") is null,
    "An invalid upstream address must not produce an exit summary or protocol label.");
Require(new ExitSummary("not-an-ip", "位置未知").IpVersion is null,
    "An invalid local address must never be inferred as IPv4 or IPv6.");
Require(new ExitSummary("127.1", "位置未知").IpVersion is null &&
        new ExitSummary("198.51.100.024", "位置未知").IpVersion is null &&
        new ExitSummary("fe80::1%12", "位置未知").IpVersion is null,
    "Non-canonical, zero-padded, or scoped addresses must not receive a protocol label.");

var blankCountrySummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","country_name":"  ","country":"US","region":"California","city":"Mountain View"}""");
Require(blankCountrySummary?.Location == "US · California · Mountain View",
    "A blank country_name must not block a non-empty country fallback.");
var cityOnlySummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","city":"Mountain View"}""");
Require(cityOnlySummary?.Location == "国家/地区未知",
    "Region and city must not be displayed without a country.");
var duplicateLocationSummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","country_name":"Singapore","region":"Singapore","city":"Singapore"}""");
Require(duplicateLocationSummary?.Location == "Singapore",
    "Repeated country, region, and city values must be deduplicated.");
Require(ExitSummaryService.ParseResponse("[]") is null &&
        ExitSummaryService.ParseResponse("null") is null &&
        ExitSummaryService.ParseResponse("\"unexpected\"") is null,
    "Valid non-object JSON roots must fail safely without throwing.");
Require(ExitSummaryService.ParseResponse(
        """{"error":true,"ip":"8.8.8.8","city":"Mountain View","country":"US"}""") is null,
    "An upstream error response must not be accepted even if it contains IP-like fields.");
Require(ExitSummaryService.ParseResponse(
        """{"error":"true","ip":"8.8.8.8","city":"Mountain View","country":"US"}""") is null,
    "A string-valued upstream error flag must also fail closed.");
Require(ExitSummaryService.ParseResponse(
        """{"error":1,"ip":"8.8.8.8","city":"Mountain View","country":"US"}""") is null &&
        ExitSummaryService.ParseResponse(
        """{"error":{"reason":"blocked"},"ip":"8.8.8.8"}""") is null,
    "Numeric and structured upstream error flags must fail closed.");
var normalizedLocationSummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","country_name":" New   Zealand ","region_name":" Auckland \n Region ","city":"Auckland"}""");
Require(normalizedLocationSummary?.Location == "New Zealand · Auckland Region · Auckland",
    "Location whitespace and region_name fallback must normalize consistently.");
var oversizedLocationSummary = ExitSummaryService.ParseResponse(
    "{\"ip\":\"8.8.4.4\",\"country_name\":\"Canada\",\"city\":\"" +
    new string('x', 129) + "\"}");
Require(oversizedLocationSummary?.Location == "Canada",
    "An oversized location field must not expand the dashboard indefinitely.");
var longCombinedLocationSummary = ExitSummaryService.ParseResponse(
    "{\"ip\":\"8.8.4.4\",\"country_name\":\"" + new string('a', 60) +
    "\",\"region\":\"" + new string('b', 60) +
    "\",\"city\":\"" + new string('c', 60) + "\"}");
Require(longCombinedLocationSummary?.Location.Length == 160 &&
        longCombinedLocationSummary.Location.EndsWith('…'),
    "The combined Windows location must remain bounded when all fields are individually valid.");
var bidiLocationSummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","country_name":"Canada","city":"safe\u202Etxt"}""");
Require(bidiLocationSummary?.Location == "Canada",
    "Bidirectional control characters from upstream location data must not reach Windows UI.");
var numericCountrySummary = ExitSummaryService.ParseResponse(
    """{"ip":"8.8.4.4","country_name":840,"city":"Mountain View"}""");
Require(numericCountrySummary?.Location == "国家/地区未知",
    "Non-string country metadata must not masquerade as a complete country result.");

foreach (var rejectedAddress in new[]
         {
             "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1",
             "192.0.2.1", "192.31.196.1", "192.52.193.1", "192.168.1.1", "192.175.48.1",
             "198.18.0.1", "198.51.100.1", "203.0.113.1",
             "224.0.0.1", "::1", "fc00::1", "fe80::1", "2001:db8::1", "2001:2::1",
             "2001:1::1", "2001:3::1", "2001:10::1", "2001:20::1", "2002::1",
             "2620:4f:8000::1", "3fff::1"
         })
{
    Require(!ExitSummary.TryNormalizePublicAddress(rejectedAddress, out _),
        $"Non-public address {rejectedAddress} must be rejected.");
}
Require(ExitSummary.TryNormalizePublicAddress(
        "2606:4700:4700:0000:0000:0000:0000:1111",
        out var canonicalIpv6) && canonicalIpv6 == "2606:4700:4700::1111",
    "Equivalent IPv6 forms must normalize to one canonical address.");
Require(ExitSummary.SelectConsensusAddress(["8.8.8.8", null, null]) is null,
    "A single fallback source must not become a high-confidence main result.");
Require(ExitSummary.SelectConsensusAddress(["8.8.8.8", "1.1.1.1", null]) is null,
    "A tied fallback result must not choose the first source.");
Require(ExitSummary.SelectConsensusAddress(["8.8.8.8", "8.8.8.8", "1.1.1.1"]) == "8.8.8.8",
    "A strict fallback majority must select the canonical majority address.");
Require(ExitSummary.SelectConsensusAddress([
        "8.8.8.8", "8.8.8.8", "1.1.1.1", "9.9.9.9"]) is null,
    "A unique plurality that is only half of the valid observations is not a strict majority.");
Require(ExitSummary.SelectConsensusAddress([
        "8.8.8.8", "8.8.8.8", "8.8.8.8", "1.1.1.1", "9.9.9.9"]) == "8.8.8.8",
    "More than half of all valid independent observations must form a strict majority.");
Require(ExitSummary.SelectConsensusAddress([
        "2606:4700:4700::1111",
        "2606:4700:4700:0000:0000:0000:0000:1111",
        "2001:4860:4860::8888"]) == "2606:4700:4700::1111",
    "Equivalent IPv6 spellings must form one majority group.");

var fallbackRequests = new ConcurrentBag<(bool NoCache, bool NoStore, TimeSpan? MaxAge, bool Pragma)>();
var fallbackHosts = new ConcurrentBag<string>();
var fallbackStarted = 0;
var fallbackGate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
using (var fallbackClient = new HttpClient(new StubHttpMessageHandler(async (request, cancellationToken) =>
       {
           fallbackHosts.Add(request.RequestUri?.Host ?? "<missing>");
           fallbackRequests.Add((
               request.Headers.CacheControl?.NoCache == true,
               request.Headers.CacheControl?.NoStore == true,
               request.Headers.CacheControl?.MaxAge,
               request.Headers.Pragma.Any(value => value.Name.Equals("no-cache", StringComparison.OrdinalIgnoreCase))));
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return TextResponse(HttpStatusCode.OK, """{"error":true,"reason":"test"}""");
           }

           if (request.RequestUri.Host == "api.ipify.org")
           {
               return TextResponse(HttpStatusCode.OK, "8.8.8.8");
           }

           if (Interlocked.Increment(ref fallbackStarted) == 3)
           {
               fallbackGate.TrySetResult(true);
           }
           await fallbackGate.Task.WaitAsync(cancellationToken);
           if (request.RequestUri.Host == "ipwho.is")
           {
               return TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"8.8.8.8","country":"United States","region":"Virginia","city":"Ashburn"}""");
           }
           var address = request.RequestUri.Host == "ip.sb" ? "1.1.1.1" : "8.8.8.8";
           return TextResponse(HttpStatusCode.OK, address);
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var fallbackSummary = await ExitSummaryService.ResolveWithClientAsync(fallbackClient);
    Require(fallbackSummary.Address == "8.8.8.8" &&
            fallbackSummary.Location == "United States · Virginia · Ashburn",
        $"An error response must use a strict IP majority and matching country-bearing fallback; " +
        $"actual address={fallbackSummary.Address}, location={fallbackSummary.Location}, " +
        $"fallback-started={fallbackStarted}, hosts={string.Join(',', fallbackHosts.Order())}.");
}
Require(fallbackStarted == 3 && fallbackRequests.Count == 5,
    "The three remaining independent sources must start concurrently after primary verification fails.");
Require(fallbackRequests.All(request =>
        request.NoCache && request.NoStore && request.MaxAge == TimeSpan.Zero && request.Pragma),
    "Every exit lookup request must explicitly disable intermediary and client caching.");

var confirmedPrimaryRequests = 0;
var confirmedPrimaryGate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
using (var confirmedPrimaryClient = new HttpClient(new StubHttpMessageHandler(async (request, cancellationToken) =>
       {
           if (Interlocked.Increment(ref confirmedPrimaryRequests) == 2)
           {
               confirmedPrimaryGate.TrySetResult(true);
           }
           await confirmedPrimaryGate.Task.WaitAsync(cancellationToken);
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return TextResponse(HttpStatusCode.OK,
                   """{"ip":"8.8.8.8","country_name":"United States","region":"Virginia","city":"Ashburn"}""");
           }
           if (request.RequestUri.Host == "api.ipify.org")
           {
               return TextResponse(HttpStatusCode.OK, "8.8.8.8");
           }
           throw new InvalidOperationException($"Unexpected confirmation request: {request.RequestUri}");
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(confirmedPrimaryClient);
    Require(summary.Address == "8.8.8.8" &&
            summary.Location == "United States · Virginia · Ashburn" &&
            confirmedPrimaryRequests == 2,
        "A valid primary summary must receive one independent IP confirmation.");
}

using (var conflictingPrimaryClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"ip":"8.8.8.8","country_name":"United States","city":"Ashburn"}"""));
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"1.1.1.1","country":"Australia","city":"Sydney"}"""));
           }
           var address = request.RequestUri.Host == "ip.sb" ? "8.8.8.8" : "1.1.1.1";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(conflictingPrimaryClient);
    Require(summary.Address == "1.1.1.1" && summary.Location == "Australia · Sydney",
        "A conflicting primary response must lose to the strict independent consensus.");
}

using (var partialPrimaryClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"ip":"8.8.8.8","city":"Ashburn"}"""));
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"8.8.8.8","country":"United States","region":"Virginia","city":"Ashburn"}"""));
           }
           var address = request.RequestUri.Host == "ip.sb" ? "1.1.1.1" : "8.8.8.8";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(partialPrimaryClient);
    Require(summary.Address == "8.8.8.8" &&
            summary.Location == "United States · Virginia · Ashburn",
        "A city-only primary response must use a matching country-bearing fallback.");
}

using (var ioFailureClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.ServiceUnavailable, "unavailable"));
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"8.8.8.8","country":"United States"}"""));
           }
           if (request.RequestUri.Host == "ip.sb")
           {
               throw new IOException("simulated response stream failure");
           }
           return Task.FromResult(TextResponse(HttpStatusCode.OK, "8.8.8.8"));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var ioFailureSummary = await ExitSummaryService.ResolveWithClientAsync(ioFailureClient);
    Require(ioFailureSummary.Address == "8.8.8.8",
        "One fallback I/O failure must not discard the other two matching public addresses.");
}

foreach (var unsafePrimary in new[]
         {
             "[]",
             "null",
             """{"error":true,"ip":"8.8.8.8"}""",
             new string('x', (64 * 1024) + 1)
         })
{
    using var fallbackClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
    {
        if (request.RequestUri!.Host == "ipapi.co")
        {
            return Task.FromResult(TextResponse(HttpStatusCode.OK, unsafePrimary));
        }
        if (request.RequestUri.Host == "ipwho.is")
        {
            return Task.FromResult(TextResponse(HttpStatusCode.OK,
                """{"success":true,"ip":"8.8.8.8","country":"United States"}"""));
        }

        var address = request.RequestUri.Host == "ip.sb" ? "1.1.1.1" : "8.8.8.8";
        return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
    })) { Timeout = TimeSpan.FromSeconds(5) };
    var fallbackSummary = await ExitSummaryService.ResolveWithClientAsync(fallbackClient);
    Require(fallbackSummary.Address == "8.8.8.8",
        "Non-object, error, and oversized primary responses must safely reach majority fallback.");
}

var oversizedValidPrimary =
    "{\"ip\":\"8.8.8.8\",\"country_name\":\"United States\",\"padding\":\"" +
    new string('x', 64 * 1024) + "\"}";
using (var oversizedPrimaryClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK, oversizedValidPrimary));
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"1.1.1.1","country":"Australia"}"""));
           }
           var address = request.RequestUri.Host == "ifconfig.me" ? "1.1.1.1" : "8.8.8.8";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(oversizedPrimaryClient);
    Require(summary == ExitSummary.Unavailable(),
        "An oversized but otherwise valid primary response must not turn a tied remainder into a result.");
}

using (var redirectedPrimaryClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               var response = TextResponse(HttpStatusCode.OK,
                   """{"ip":"8.8.8.8","country_name":"United States"}""");
               response.RequestMessage = new HttpRequestMessage(
                   HttpMethod.Get,
                   "https://redirect.invalid/result");
               return Task.FromResult(response);
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"1.1.1.1","country":"Australia"}"""));
           }
           var address = request.RequestUri.Host == "ifconfig.me" ? "1.1.1.1" : "8.8.8.8";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(redirectedPrimaryClient);
    Require(summary == ExitSummary.Unavailable(),
        "A response whose final URL differs from the requested endpoint must fail closed.");
}

var invalidUtf8Primary = System.Text.Encoding.UTF8.GetBytes(
        "{\"ip\":\"8.8.8.8\",\"country_name\":\"")
    .Concat(new byte[] { 0xFF })
    .Concat(System.Text.Encoding.UTF8.GetBytes("\"}"))
    .ToArray();
using (var invalidUtf8Client = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
               {
                   Content = new ByteArrayContent(invalidUtf8Primary)
               });
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"1.1.1.1","country":"Australia"}"""));
           }
           var address = request.RequestUri.Host == "ifconfig.me" ? "1.1.1.1" : "8.8.8.8";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var summary = await ExitSummaryService.ResolveWithClientAsync(invalidUtf8Client);
    Require(summary == ExitSummary.Unavailable(),
        "Invalid UTF-8 must be rejected instead of surfacing replacement characters as country data.");
}

using (var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100)))
using (var cancellationClient = new HttpClient(new StubHttpMessageHandler(async (_, token) =>
       {
           await Task.Delay(Timeout.InfiniteTimeSpan, token);
           return TextResponse(HttpStatusCode.OK, "8.8.8.8");
       })) { Timeout = TimeSpan.FromSeconds(5) })
{
    var cancellationPropagated = false;
    try
    {
        await ExitSummaryService.ResolveWithClientAsync(cancellationClient, cancellation.Token);
    }
    catch (OperationCanceledException)
    {
        cancellationPropagated = true;
    }
    Require(cancellationPropagated,
        "Caller cancellation must stop the current route lookup instead of being converted into fallback traffic.");
}

var totalBudgetRequests = 0;
using (var totalBudgetClient = new HttpClient(new StubHttpMessageHandler(async (_, token) =>
       {
           Interlocked.Increment(ref totalBudgetRequests);
           await Task.Delay(Timeout.InfiniteTimeSpan, token);
           return TextResponse(HttpStatusCode.OK, "8.8.8.8");
       })) { Timeout = Timeout.InfiniteTimeSpan })
{
    var startedAt = DateTime.UtcNow;
    var summary = await ExitSummaryService.ResolveWithClientAsync(
        totalBudgetClient,
        requestTimeout: TimeSpan.FromSeconds(5),
        totalTimeout: TimeSpan.FromMilliseconds(100));
    Require(summary == ExitSummary.Unavailable(),
        "An exhausted total exit-lookup budget must produce an unavailable result.");
    Require(DateTime.UtcNow - startedAt < TimeSpan.FromSeconds(2),
        "The total exit-lookup budget must cancel stalled requests promptly.");
    Require(totalBudgetRequests == 2,
        "A total timeout during the concurrent primary pair must not launch second-stage fallback traffic.");
}

using (var stalledBodyClient = new HttpClient(new StubHttpMessageHandler((request, _) =>
       {
           if (request.RequestUri!.Host == "ipapi.co")
           {
               return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
               {
                   Content = new StreamContent(new CancellationOnlyStream())
               });
           }
           if (request.RequestUri.Host == "ipwho.is")
           {
               return Task.FromResult(TextResponse(HttpStatusCode.OK,
                   """{"success":true,"ip":"8.8.8.8","country":"United States"}"""));
           }
           var address = request.RequestUri.Host == "ip.sb" ? "1.1.1.1" : "8.8.8.8";
           return Task.FromResult(TextResponse(HttpStatusCode.OK, address));
       })) { Timeout = Timeout.InfiniteTimeSpan })
{
    var startedAt = DateTime.UtcNow;
    var fallbackSummary = await ExitSummaryService.ResolveWithClientAsync(
        stalledBodyClient,
        requestTimeout: TimeSpan.FromMilliseconds(100));
    Require(fallbackSummary.Address == "8.8.8.8",
        "A primary response that stalls after its headers must time out and reach majority fallback.");
    Require(DateTime.UtcNow - startedAt < TimeSpan.FromSeconds(2),
        "The explicit exit lookup deadline must cover response-body streaming.");
}

using (var stalledControllerClient = new HttpClient(new StubHttpMessageHandler((_, _) =>
       Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
       {
           Content = new StreamContent(new CancellationOnlyStream())
       })))
       {
           BaseAddress = new Uri("http://localhost"),
           Timeout = Timeout.InfiniteTimeSpan
       })
{
    var timedOut = false;
    try
    {
        using var _ = await MihomoControllerService.GetJsonWithClientAsync(
            stalledControllerClient,
            "/configs",
            TimeSpan.FromMilliseconds(100));
    }
    catch (OperationCanceledException)
    {
        timedOut = true;
    }
    Require(timedOut,
        "A local controller response that stalls after its headers must respect the full-body deadline.");
}

if (string.Equals(
        Environment.GetEnvironmentVariable("PROXYGAUGE_LIVE_EXIT_TEST"),
        "1",
        StringComparison.Ordinal))
{
    var liveSummary = await ExitSummaryService.ResolveAsync(new AppConfig
    {
        MixedHost = "127.0.0.1",
        MixedPort = 9,
        TimeoutSeconds = 10
    });
    Require(ExitSummary.IsSupportedAddress(liveSummary.Address),
        "The live Windows system route must resolve a canonical public exit without using MixedPort.");
    Console.WriteLine("ProxyGauge live Windows system-route lookup passed without printing the address.");
}

var darkPalette = ThemeService.GetPalette(AppThemeKind.Dark);
var lightPalette = ThemeService.GetPalette(AppThemeKind.Light);
Require(darkPalette.Keys.ToHashSet().SetEquals(lightPalette.Keys),
    "Light and dark themes must provide the same color tokens.");
Require(darkPalette["CanvasColor"] != lightPalette["CanvasColor"],
    "Light and dark themes must use distinct canvas colors.");
Require(lightPalette["CanvasColor"] == "#FFFFFFFF",
    "The Windows light canvas must match the macOS light canvas.");
foreach (var palette in new[] { darkPalette, lightPalette })
{
    Require(ContrastRatio(palette["TextColor"], palette["CanvasColor"]) >= 7,
        "Primary text must retain enhanced contrast against the app canvas.");
    Require(ContrastRatio(palette["TextColor"], palette["SurfaceColor"]) >= 7,
        "Primary text must retain enhanced contrast against cards.");
    Require(ContrastRatio(palette["AccentColor"], palette["SurfaceColor"]) >= 4.5,
        "The interactive accent must remain legible in both themes.");
}

var themeResources = new ResourceDictionary();
ThemeService.ApplyPalette(themeResources, darkPalette);
var previousCanvasBrush = themeResources["CanvasBrush"];
ThemeService.ApplyPalette(themeResources, lightPalette);
Require(themeResources["CanvasColor"] is Color canvasColor && canvasColor == Colors.White,
    "Applying the light palette must update the color token.");
Require(themeResources["CanvasBrush"] is SolidColorBrush canvasBrush && canvasBrush.Color == Colors.White,
    "Applying the light palette must replace the matching brush token.");
Require(!ReferenceEquals(previousCanvasBrush, themeResources["CanvasBrush"]),
    "Runtime theme changes must replace brushes so DynamicResource consumers are invalidated.");

Exception? wpfFailure = null;
var wpfThread = new Thread(() =>
{
    App? app = null;
    MainWindow? mainWindow = null;
    SettingsWindow? settingsWindow = null;
    UpdateService? updateService = null;
    try
    {
        Console.WriteLine("WPF validation: loading application resources.");
        app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.InitializeComponent();

        var artifactDirectory = Environment.GetEnvironmentVariable("PROXYGAUGE_TEST_ARTIFACT_DIR");
        string? Artifact(string name) => string.IsNullOrWhiteSpace(artifactDirectory)
            ? null
            : Path.Combine(artifactDirectory, name);

        ThemeService.ApplyPalette(app.Resources, lightPalette);
        using var themeService = new ThemeService();
        Console.WriteLine("WPF validation: rendering light dashboard.");
        mainWindow = new MainWindow(themeService);
        var mainRoot = (Border)mainWindow.Content;
        var dashboardScroller = (ScrollViewer)mainWindow.FindName("DashboardScrollViewer");
        Require(dashboardScroller.VerticalScrollBarVisibility == ScrollBarVisibility.Hidden,
            "The dashboard must remain wheel-scrollable without showing a stray side scrollbar.");
        Require(mainWindow.FindName("ProductTitle") is TextBlock { Text: "ProxyGauge" } &&
                mainWindow.FindName("ProductIntroduction") is TextBlock { Text: "监控代理连接、出口 IP 与浏览器隐私" },
            "The page must retain its title and subtitle while the native caption stays unbranded.");
        Require(mainRoot.BorderThickness == new Thickness(0) &&
                mainWindow.Background is SolidColorBrush { Color.A: 255 },
            "The main frame must not cut a square WPF outline into disconnected rounded edges.");
        NativeFrameAssertions.Check(mainWindow);
        var locationChip = (TextBlock)mainWindow.FindName("ExitLocationChip");
        Require(mainWindow.FindName("ExitCardTitle") is TextBlock { Text: "系统实际出口" },
            "The main card must name the operating-system route instead of implying a configured proxy-port result.");
        Require(locationChip.GetBindingExpression(TextBlock.TextProperty)?.ParentBinding.Path.Path == "ExitLocation",
            "The exit chip must display the city/region value.");
        Require(locationChip.MaxHeight == 34 && locationChip.TextTrimming == TextTrimming.CharacterEllipsis,
            "A long exit location must not overflow the fixed-height Windows card.");
        var ipVersionChip = (TextBlock)mainWindow.FindName("ExitIpVersionChip");
        Require(ipVersionChip.GetBindingExpression(TextBlock.TextProperty)?.ParentBinding.Path.Path == "ExitIpVersion",
            "The protocol chip must display the IP version derived locally from the exit address.");
        Require(locationChip.Parent is Border locationBorder &&
                ipVersionChip.Parent is Border groupedIpVersionBorder &&
                ReferenceEquals(locationBorder.Parent, groupedIpVersionBorder.Parent) &&
                locationBorder.Parent is StackPanel { Orientation: Orientation.Horizontal },
            "The city/region and IP version chips must remain visually grouped side by side.");
        var ipVersionBorder = (Border)mainWindow.FindName("ExitIpVersionBorder");
        Require(ipVersionBorder.GetBindingExpression(UIElement.VisibilityProperty)?.ParentBinding.Path.Path == "HasExitIpVersion",
            "The protocol chip must be hidden while no valid exit address is available.");
        mainRoot.Measure(new Size(820, 550));
        mainRoot.Arrange(new Rect(0, 0, 820, 550));
        mainRoot.UpdateLayout();
        Require(ipVersionBorder.Visibility == Visibility.Collapsed,
            "The unavailable dashboard must not render a placeholder protocol chip.");
        Require(mainWindow.FindName("ExitNetworkTypeChip") is null,
            "The dashboard must not contain an IP type chip.");

        var mainViewModel = (ProxyGauge.ViewModels.MainViewModel)mainWindow.DataContext;
        var applyExit = typeof(ProxyGauge.ViewModels.MainViewModel).GetMethod(
            "ApplyExit", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The deterministic WPF test could not locate ApplyExit.");
        applyExit.Invoke(mainViewModel, [new ExitSummary("8.8.8.8", "美国 · 加利福尼亚 · 洛杉矶")]);
        Require(ipVersionChip.Text == "IPv4" && ipVersionBorder.Visibility == Visibility.Visible,
            "A valid IPv4 exit must render the local protocol chip.");
        var showCopyFeedback = typeof(MainWindow).GetMethod(
            "ShowCopyFeedback", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The deterministic WPF test could not locate ShowCopyFeedback.");
        var copyFeedbackCancellation = typeof(MainWindow).GetField(
            "_copyFeedbackCancellation", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("The deterministic WPF test could not locate copy feedback cancellation state.");
        var copyCheckmark = (System.Windows.Shapes.Path)mainWindow.FindName("CopyExitCheckmark");
        var copyFront = (System.Windows.Shapes.Rectangle)mainWindow.FindName("CopyExitFront");
        showCopyFeedback.Invoke(mainWindow, null);
        var firstCopyCancellation = (CancellationTokenSource?)copyFeedbackCancellation.GetValue(mainWindow)
            ?? throw new InvalidOperationException("The first copy feedback did not create a cancellable lifetime.");
        showCopyFeedback.Invoke(mainWindow, null);
        var secondCopyCancellation = (CancellationTokenSource?)copyFeedbackCancellation.GetValue(mainWindow)
            ?? throw new InvalidOperationException("The second copy feedback did not replace its cancellable lifetime.");
        Require(firstCopyCancellation.IsCancellationRequested &&
                !secondCopyCancellation.IsCancellationRequested &&
                !ReferenceEquals(firstCopyCancellation, secondCopyCancellation),
            "A repeated copy must cancel the previous feedback delay and start a fresh lifetime.");
        applyExit.Invoke(mainViewModel, [new ExitSummary("1.1.1.1", "澳大利亚 · 悉尼")]);
        Require(secondCopyCancellation.IsCancellationRequested &&
                copyCheckmark.Visibility == Visibility.Collapsed &&
                copyFront.Visibility == Visibility.Visible,
            "Changing the exit address must immediately cancel and reset stale copy-success feedback.");
        var lightPixels = RenderPixels(mainRoot, 820, 550, Artifact("main-light.png"));

        var applyGuard = typeof(ProxyGauge.ViewModels.MainViewModel).GetMethod(
            "ApplyGuard", BindingFlags.Instance | BindingFlags.NonPublic)!;
        applyGuard.Invoke(mainViewModel, [new GuardStatus(GuardStatusKind.Enabled, true, 17)
            { AutomaticSelection = true, ProxyExecutablePath = @"C:\Clash\verge-mihomo.exe" }]);
        applyExit.Invoke(mainViewModel, [ExitSummary.Disconnected()]);
        RenderPixels(mainRoot, 820, 550, Artifact("main-disconnected-guard-on.png"));
        Require(mainViewModel.ExitAddress == "已断开网络连接" && ipVersionBorder.Visibility == Visibility.Collapsed &&
                mainViewModel.ConnectionDetail == "Clash Verge Rev · verge-mihomo" &&
                mainViewModel.GuardApplicationLabel == "切换代理",
            "The proxy card must show the client and core while the guard card keeps a short switch action.");
        applyGuard.Invoke(mainViewModel, [new GuardStatus(GuardStatusKind.Enabled, true, 17)
            { AutomaticSelection = true, ProxyExecutablePath = @"C:\Clash\verge-mihomo.exe", SelectionRequired = true }]);
        RenderPixels(mainRoot, 820, 550, Artifact("main-disconnected-selection-required.png"));
        Require(mainViewModel.ExitAddress == "已断开网络连接" && ipVersionBorder.Visibility == Visibility.Collapsed &&
                mainViewModel.GuardApplicationLabel == "选择当前代理" &&
                mainViewModel.GuardDetail.Contains("保护继续生效"),
            "An ambiguous entry must visibly request a selection while keeping protection and offline state visible.");
        applyGuard.Invoke(mainViewModel, [new GuardStatus(GuardStatusKind.Disabled, true, 0)]);
        applyExit.Invoke(mainViewModel, [new ExitSummary("1.1.1.1", "澳大利亚 · 悉尼")]);
        Require(RequireSolidColor(mainRoot.Background,
                    "The main window root must use a solid canvas brush in light mode.") == Colors.White,
            "The already-created main window must resolve the light canvas to white.");
        Require(CountExactColor(lightPixels, Colors.White) > 200_000,
            "The Windows-rendered light dashboard must contain its white canvas and surfaces.");

        applyExit.Invoke(mainViewModel, [new ExitSummary("2606:4700:4700::1111", "美国 · 加利福尼亚 · 洛杉矶")]);
        RenderPixels(mainRoot, 820, 550, Artifact("main-ipv6.png"));
        Require(ipVersionChip.Text == "IPv6" && ipVersionBorder.Visibility == Visibility.Visible,
            "A valid IPv6 exit must render the local protocol chip without changing the network request.");
        applyExit.Invoke(mainViewModel, [new ExitSummary("8.8.8.8", "美国 · 加利福尼亚 · 洛杉矶")]);

        var chevronGeometry = app.Resources["IconChevron"];
        var chevrons = VisualDescendants(mainRoot)
            .OfType<System.Windows.Shapes.Path>()
            .Where(path => ReferenceEquals(path.Data, chevronGeometry))
            .ToArray();
        Require(chevrons.Length == 4,
            "The dashboard must render all four navigation chevrons.");
        Require(chevrons.All(path => path.Width == 7 && path.Height == 12 && path.Stretch == Stretch.Fill),
            "Every navigation chevron must fill its explicit 7x12 frame.");

        ThemeService.ApplyPalette(app.Resources, darkPalette);
        Console.WriteLine("WPF validation: rendering runtime-dark dashboard.");
        var runtimeDarkPixels = RenderPixels(mainRoot, 820, 550, Artifact("main-runtime-dark.png"));
        var darkCanvas = (Color)ColorConverter.ConvertFromString(darkPalette["CanvasColor"]);
        var darkSurface = (Color)ColorConverter.ConvertFromString(darkPalette["SurfaceColor"]);
        Require(RequireSolidColor(mainRoot.Background,
                    "The main window root must use a solid canvas brush after a runtime switch.") == darkCanvas,
            "The already-created main window must update to the dark canvas without being recreated.");
        Require(CountExactColor(runtimeDarkPixels, darkCanvas) > 50_000,
            "The Windows-rendered dashboard must contain the runtime dark canvas.");
        Require(CountExactColor(runtimeDarkPixels, darkSurface) > 50_000,
            "The Windows-rendered dashboard must contain the runtime dark card surfaces.");

        var probeService = new ProxyProbeService();
        var controllerService = new MihomoControllerService();
        var discoveryService = new ConnectionDiscoveryService(probeService, controllerService);
        updateService = new UpdateService();
        Console.WriteLine("WPF validation: rendering runtime-dark settings.");
        var guardPicker = new GuardApplicationWindow(new GuardApplicationRequest("PROXY_AMBIGUOUS",
            [new("iKuuu", chosenCore), new("Mihomo", @"C:\Clash\mihomo.exe")], ""));
        Require(guardPicker.FindName("PortTextBox") is null && guardPicker.FindName("HostTextBox") is null &&
            guardPicker.FindName("ApplicationList") is ListBox { Items.Count: 2, SelectedIndex: -1 } &&
            guardPicker.FindName("EnableButton") is Button { IsEnabled: false },
            "The fallback picker must contain applications only, with no endpoint fields or implicit selection.");
        RenderPixels((Border)guardPicker.Content, 560, 350, Artifact("guard-picker-dark.png"));
        Require(!guardPicker.IsVisible, "Picker validation must use an offscreen render, not GUI automation.");
        guardPicker.Close();
        settingsWindow = new SettingsWindow(
            new AppConfig(),
            discoveryService,
            updateService);
        var proxyChoice = (ComboBox)settingsWindow.FindName("ProxyApplicationComboBox");
        Require(proxyChoice.SelectedItem is ProxyApplicationChoice { ExecutablePath: "" },
            "Settings must default to automatic Clash/Mihomo selection.");
        typeof(SettingsWindow).GetMethod("LoadProxyApplications", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(settingsWindow, [chosenCore, Array.Empty<ProxyApplicationChoice>()]);
        Require(proxyChoice.SelectedItem is ProxyApplicationChoice selected && selected.ExecutablePath == chosenCore,
            "Settings must retain an explicitly chosen core even when that executable is stopped.");
        Require(settingsWindow.FindName("VersionText") is TextBlock
                { Text: var settingsVersionText } &&
                settingsVersionText == $"当前版本 v{expectedProductVersion}",
            "The settings page must display the product version even under a distinct test host.");
        var settingsRoot = (Border)settingsWindow.Content;
        var settingsDarkPixels = RenderPixels(settingsRoot, 510, 670, Artifact("settings-runtime-dark.png"));
        Require(RequireSolidColor(settingsRoot.Background,
                    "The settings window root must use a solid canvas brush.") == darkCanvas,
            "A settings window opened after the switch must use the dark canvas.");
        Require(CountExactColor(settingsDarkPixels, darkCanvas) > 100_000,
            "The Windows-rendered settings window must contain the dark canvas.");

        ThemeService.ApplyPalette(app.Resources, lightPalette);
        Console.WriteLine("WPF validation: rendering dashboard after switching back to light.");
        var runtimeLightPixels = RenderPixels(mainRoot, 820, 550, Artifact("main-runtime-light.png"));
        Require(RequireSolidColor(mainRoot.Background,
                    "The main window root must retain a solid canvas brush after switching back.") == Colors.White,
            "The already-created main window must switch back to the white canvas.");
        Require(RequireSolidColor(settingsRoot.Background,
                    "The settings window root must remain bound to the shared canvas brush.") == Colors.White,
            "The already-created settings window must also switch back to the white canvas.");
        Require(CountExactColor(runtimeLightPixels, Colors.White) > 200_000,
            "The Windows-rendered dashboard must return to its light canvas and surfaces.");

        var settingsLifetimeCancellation = (CancellationTokenSource?)(
            typeof(SettingsWindow).GetField(
                "_lifetimeCancellation",
                BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(settingsWindow))
            ?? throw new InvalidOperationException("The settings window does not expose a cancellable operation lifetime.");
        settingsWindow.Close();
        Require(settingsLifetimeCancellation.IsCancellationRequested,
            "Closing settings must cancel discovery/update callbacks before they can publish UI or launch an installer.");
        settingsWindow = null;

        showCopyFeedback.Invoke(mainWindow, null);
        var closingCopyCancellation = (CancellationTokenSource?)copyFeedbackCancellation.GetValue(mainWindow)
            ?? throw new InvalidOperationException("Window-lifetime copy feedback did not start.");
        var mainLifetimeCancellation = (CancellationTokenSource?)(
            typeof(MainWindow).GetField(
                "_lifetimeCancellation",
                BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(mainWindow))
            ?? throw new InvalidOperationException("The main window does not expose a cancellable operation lifetime.");
        mainWindow.Close();
        Require(closingCopyCancellation.IsCancellationRequested &&
                mainLifetimeCancellation.IsCancellationRequested,
            "Closing the window must cancel copy feedback, refresh, and updater lifetimes.");
        mainWindow = null;
    }
    catch (Exception exception)
    {
        wpfFailure = exception;
    }
    finally
    {
        updateService?.Dispose();
        settingsWindow?.Close();
        mainWindow?.Close();
        app?.Shutdown();
        System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeShutdown();
    }
});
wpfThread.SetApartmentState(ApartmentState.STA);
wpfThread.IsBackground = true;
wpfThread.Start();
Require(wpfThread.Join(TimeSpan.FromSeconds(30)),
    "Windows WPF rendering validation must finish within 30 seconds.");
if (wpfFailure is not null)
{
    throw new InvalidOperationException("Windows WPF rendering validation failed.", wpfFailure);
}

Require(LocalEndpointPolicy.IsLoopbackHost("127.0.0.1"), "IPv4 loopback must be accepted.");
Require(LocalEndpointPolicy.IsLoopbackHost("127.42.0.9"), "The IPv4 loopback range must be accepted.");
Require(LocalEndpointPolicy.IsLoopbackHost("localhost"), "localhost must be accepted.");
Require(LocalEndpointPolicy.IsLoopbackHost("[::1]"), "Bracketed IPv6 loopback must be accepted.");
Require(!LocalEndpointPolicy.IsLoopbackHost("192.0.2.1"), "Remote IPv4 addresses must be rejected.");
Require(!LocalEndpointPolicy.IsLoopbackHost("example.com"), "Remote hostnames must be rejected.");
Require(LocalEndpointPolicy.NormalizeLoopbackHost("localhost") == "127.0.0.1",
    "localhost must normalize to the canonical IPv4 loopback.");
Require(LocalEndpointPolicy.NormalizeLoopbackHost("[::1]") == "::1",
    "IPv6 loopback brackets must be normalized.");
Require(LocalEndpointPolicy.NormalizeLoopbackHost("0:0:0:0:0:0:0:1") == "::1",
    "Expanded IPv6 loopback must normalize to the canonical address.");
Require(LocalEndpointPolicy.FormatEndpoint("::1", 7890) == "[::1]:7890" &&
        LocalEndpointPolicy.FormatEndpoint("127.0.0.1", 7890) == "127.0.0.1:7890",
    "IPv6 endpoints must use brackets without changing IPv4 endpoint formatting.");
Require(!LocalEndpointPolicy.IsLoopbackHost("127.000.0.1") &&
        !LocalEndpointPolicy.IsLoopbackHost("127.1"),
    "Non-canonical abbreviated or leading-zero IPv4 input must fail closed.");
Require(LocalEndpointPolicy.NormalizeLoopbackHost("192.0.2.1") == "127.0.0.1",
    "Invalid saved hosts must fail closed to the local default.");

var matchingSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "127.0.0.1:7890",
    null);
Require(matchingSystemProxy.Enabled && matchingSystemProxy.Matches("localhost", 7890),
    "An explicit Windows proxy must be associated with the configured loopback endpoint.");
var ipv6SystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "https=[0:0:0:0:0:0:0:1]:7890",
    null);
Require(ipv6SystemProxy.Matches("::1", 7890) && ipv6SystemProxy.ExplicitEndpoint == "[::1]:7890",
    "Equivalent IPv6 loopback forms must compare and render canonically.");
var mismatchedSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "http=127.0.0.1:7890;https=127.0.0.1:7891",
    null);
Require(mismatchedSystemProxy.Enabled && !mismatchedSystemProxy.Matches("127.0.0.1", 7890) &&
        mismatchedSystemProxy.ExplicitEndpoint == "127.0.0.1:7891",
    "HTTPS ProxyServer mismatch must be surfaced instead of treating any enabled proxy as the configured port.");
var spaceSeparatedSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "http=127.0.0.1:7890 https=127.0.0.1:7891",
    null);
Require(spaceSeparatedSystemProxy.ExplicitCoversHttps &&
        spaceSeparatedSystemProxy.ExplicitEndpoint == "127.0.0.1:7891",
    "Space-delimited WinINet proxy lists must select the HTTPS endpoint.");
var httpOnlySystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "http=127.0.0.1:7890",
    null);
Require(httpOnlySystemProxy.Enabled && !httpOnlySystemProxy.ExplicitCoversHttps &&
        !httpOnlySystemProxy.Matches("127.0.0.1", 7890),
    "An HTTP-only proxy must not be treated as covering the HTTPS exit lookup.");
var pacSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    0,
    null,
    "https://proxy.example/proxy.pac");
Require(pacSystemProxy.Enabled && pacSystemProxy.PacEnabled && !pacSystemProxy.ExplicitEnabled,
    "PAC must be recognized even when ProxyEnable is zero, while remaining distinct from a fixed endpoint.");
var pacWithManualProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "http=127.0.0.1:7891",
    "https://proxy.example/proxy.pac");
Require(pacWithManualProxy.UsesDynamicResolution && pacWithManualProxy.PacEnabled &&
        pacWithManualProxy.ExplicitEnabled,
    "PAC must take diagnostic precedence when a stale or fallback manual proxy also exists.");
var wpadSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    0,
    null,
    null,
    autoDetectEnabled: true);
Require(wpadSystemProxy.Enabled && wpadSystemProxy.AutoDetectEnabled &&
        !wpadSystemProxy.PacEnabled && !wpadSystemProxy.ExplicitEnabled,
    "WPAD auto-detection must remain visible even without a fixed endpoint or PAC URL.");
var bypassedSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "127.0.0.1:7890",
    null,
    proxyBypass: "<local>;ipapi.co;*.ipify.org");
var nonBypassedSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "127.0.0.1:7890",
    null,
    proxyBypass: "<local>");
Require(bypassedSystemProxy.MayBypassExitLookup && !nonBypassedSystemProxy.MayBypassExitLookup &&
        bypassedSystemProxy != nonBypassedSystemProxy,
    "Exit-service bypass changes must invalidate the Windows proxy fingerprint.");
var wildcardBypassedSystemProxy = ProxyProbeService.ParseSystemProxyConfiguration(
    1,
    "127.0.0.1:7890",
    null,
    proxyBypass: "ms*;*ipify*;*config*;*test*");
Require(wildcardBypassedSystemProxy.MayBypassExitLookup,
    "WinINet wildcard bypass rules must not allow an exit lookup to be reported as proxied.");
var matchingProxyWithoutEnvironment = matchingSystemProxy with
{
    EnvironmentProxyEnabled = false,
    EnvironmentFingerprint = null
};
var confirmedDualRoute = ProxyProbeService.DescribeCombinedRoute(
    matchingProxyWithoutEnvironment,
    otherTunnelDetected: false,
    localMihomoHealthy: true,
    "127.0.0.1",
    7890);
Require(confirmedDualRoute.Title == "双重入口" && confirmedDualRoute.Value == "同时开启",
    "Only a healthy Mihomo endpoint and an exactly matched fixed system proxy may form a confirmed dual entry.");
var uncertainDualRoutes = new[]
{
    ProxyProbeService.DescribeCombinedRoute(
        pacSystemProxy with { EnvironmentProxyEnabled = false, EnvironmentFingerprint = null },
        false, true, "127.0.0.1", 7890),
    ProxyProbeService.DescribeCombinedRoute(
        wpadSystemProxy with { EnvironmentProxyEnabled = false, EnvironmentFingerprint = null },
        false, true, "127.0.0.1", 7890),
    ProxyProbeService.DescribeCombinedRoute(
        bypassedSystemProxy with { EnvironmentProxyEnabled = false, EnvironmentFingerprint = null },
        false, true, "127.0.0.1", 7890),
    ProxyProbeService.DescribeCombinedRoute(
        mismatchedSystemProxy with { EnvironmentProxyEnabled = false, EnvironmentFingerprint = null },
        false, true, "127.0.0.1", 7890),
    ProxyProbeService.DescribeCombinedRoute(
        httpOnlySystemProxy with { EnvironmentProxyEnabled = false, EnvironmentFingerprint = null },
        false, true, "127.0.0.1", 7890),
    ProxyProbeService.DescribeCombinedRoute(
        matchingProxyWithoutEnvironment,
        false, false, "127.0.0.1", 7890)
};
Require(uncertainDualRoutes.All(route =>
        route.Title == "系统代理 + TUN" && route.Value == "路径需确认"),
    "PAC, WPAD, bypassed, mismatched, HTTP-only, and unhealthy TUN combinations must remain unattributed system paths.");
var healthyMihomoTunnel = ProxyProbeService.DescribeMihomoTunnelRoute(mihomoCoreHealthy: true);
var residualMihomoTunnel = ProxyProbeService.DescribeMihomoTunnelRoute(mihomoCoreHealthy: false);
Require(healthyMihomoTunnel.Value == "代表性路由已确认" && healthyMihomoTunnel.Level == HealthLevel.Ok &&
        residualMihomoTunnel.Value == "检测到但未确认" && residualMihomoTunnel.Level == HealthLevel.Warning,
    "Representative TUN routes require one healthy Mihomo core but do not require a mixed listener; a residual route must warn.");
Require(TcpListenerOwnership.Classify(canConnect: false, ownedByMihomo: false) ==
        TcpListenerAttribution.Closed &&
        TcpListenerOwnership.Classify(canConnect: true, ownedByMihomo: true) ==
        TcpListenerAttribution.MihomoOwned &&
        TcpListenerOwnership.Classify(canConnect: true, ownedByMihomo: false) ==
        TcpListenerAttribution.OtherOrUnknown,
    "TCP reachability and Mihomo PID ownership must remain separate facts.");
var tunOnlyPort = ProxyProbeService.DescribeLocalPort(
    "127.0.0.1",
    7890,
    TcpListenerAttribution.Closed,
    healthyMihomoTunRoute: true);
var foreignListenerPort = ProxyProbeService.DescribeLocalPort(
    "127.0.0.1",
    7890,
    TcpListenerAttribution.OtherOrUnknown,
    healthyMihomoTunRoute: false);
var otherVpnPort = ProxyProbeService.DescribeLocalPort(
    "127.0.0.1",
    7890,
    TcpListenerAttribution.Closed,
    healthyMihomoTunRoute: false,
    alternateSystemPath: true);
Require(tunOnlyPort.Level == HealthLevel.Idle &&
        tunOnlyPort.Detail.Contains("TUN-only", StringComparison.Ordinal) &&
        otherVpnPort.Level == HealthLevel.Idle && otherVpnPort.Value == "非当前入口" &&
        foreignListenerPort.Level == HealthLevel.Warning &&
        foreignListenerPort.Detail.Contains("监听 PID 未归属", StringComparison.Ordinal),
    "A closed mixed port is optional for TUN-only/alternate system paths, while an unattributed listener must warn.");
Require(ProxyProbeService.HasHealthyMihomoPath(
            1,
            TcpListenerAttribution.Closed,
            TunnelKind.Mihomo) &&
        !ProxyProbeService.HasHealthyMihomoPath(
            1,
            TcpListenerAttribution.OtherOrUnknown,
            TunnelKind.None),
    "One nearby Mihomo core must not make an unrelated reachable port healthy, while confirmed TUN-only routing remains valid.");
var tunOnlySnapshot = TestSnapshot(7890) with
{
    Port = tunOnlyPort,
    SystemProxyEnabled = false,
    TunDetected = true
};
Require(HealthCheckService.ShouldUseTunOnlySystemRoute(tunOnlySnapshot) &&
        HealthCheckService.SelectPrimaryExitRoute(tunOnlySnapshot) == HealthExitRoute.TunSystem &&
        !HealthCheckService.ShouldUseTunOnlySystemRoute(
            tunOnlySnapshot with { SystemProxyEnabled = true }) &&
        HealthCheckService.SelectPrimaryExitRoute(
            tunOnlySnapshot with { SystemProxyEnabled = true }) == HealthExitRoute.Unavailable &&
        HealthCheckService.SelectPrimaryExitRoute(
            tunOnlySnapshot with
            {
                Port = ProxyProbeService.DescribeLocalPort(
                    "127.0.0.1",
                    7890,
                    TcpListenerAttribution.MihomoOwned,
                    healthyMihomoTunRoute: true)
            }) == HealthExitRoute.MihomoMixed,
    "The health report must follow a confirmed TUN-only system route instead of forcing a closed mixed endpoint.");
Require(ProxyProbeService.ClassifyTunnelAdapter("Mihomo", "Wintun Userspace Tunnel") == TunnelKind.Mihomo,
    "A Mihomo-named tunnel adapter must be attributed to Mihomo.");
Require(ProxyProbeService.ClassifyTunnelAdapter("WireGuard Tunnel", "Wintun") == TunnelKind.Other,
    "A generic Wintun/WireGuard adapter must be reported as another VPN instead of Mihomo TUN.");
Require(ProxyProbeService.ClassifyTunnelAdapter("Ethernet", "Intel network adapter") == TunnelKind.None,
    "A normal network adapter must not be classified as a tunnel.");
Require(ProxyProbeService.ClassifyTunnelAdapter(
        "Company connection",
        "WAN Miniport",
        NetworkInterfaceType.Ppp) == TunnelKind.Other,
    "A built-in PPP/IKEv2 VPN must be recognized even when its display name has no VPN keyword.");
Require(ProxyProbeService.ClassifyTunnelAdapter(
        "Company Ethernet",
        "Custom transport",
        NetworkInterfaceType.Ethernet,
        registryVirtual: true) == TunnelKind.VirtualNetwork,
    "A registry-confirmed virtual Ethernet adapter must not be mislabeled as a VPN/TUN.");
var dualStackMihomoEvidence = new[]
{
    new RoutedAdapterEvidence(TunnelKind.Mihomo, Ipv4Index: 17, Ipv6Index: 23)
};
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 17, Ipv6: 23),
        dualStackMihomoEvidence) == TunnelKind.Mihomo,
    "An explicitly named Mihomo adapter carrying the best route must remain Mihomo without a 198.18 route.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 31, Ipv6: 41),
        dualStackMihomoEvidence) == TunnelKind.Unknown,
    "An up adapter name alone must not claim the route, and an unmapped best interface must fail closed.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 31, Ipv6: 41),
        [
            .. dualStackMihomoEvidence,
            new RoutedAdapterEvidence(TunnelKind.None, Ipv4Index: 31, Ipv6Index: 41)
        ]) == TunnelKind.None,
    "A named Mihomo adapter that carries neither best route must not override a mapped physical route.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 17, Ipv6: 41),
        [new RoutedAdapterEvidence(TunnelKind.Mihomo, Ipv4Index: 17, Ipv6Index: null)]) ==
        TunnelKind.Split,
    "A mapped Mihomo family plus an unmapped second family must fail closed as a split route.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 51, Ipv6: null),
        [new RoutedAdapterEvidence(TunnelKind.Other, Ipv4Index: 51, Ipv6Index: null)]) == TunnelKind.Other &&
        ProxyProbeService.ClassifyRoutedAdapterEvidence(
            new BestRouteInterfaceIndexes(Ipv4: 61, Ipv6: null),
            [new RoutedAdapterEvidence(TunnelKind.VirtualNetwork, Ipv4Index: 61, Ipv6Index: null)]) ==
        TunnelKind.VirtualNetwork,
    "A generic VPN or virtual Ethernet may be reported only while it carries an actual best route.");
var ipv4MihomoIpv6Physical = new[]
{
    new RoutedAdapterEvidence(TunnelKind.Mihomo, Ipv4Index: 17, Ipv6Index: null),
    new RoutedAdapterEvidence(TunnelKind.None, Ipv4Index: null, Ipv6Index: 23)
};
var ipv4PhysicalIpv6Mihomo = new[]
{
    new RoutedAdapterEvidence(TunnelKind.None, Ipv4Index: 17, Ipv6Index: null),
    new RoutedAdapterEvidence(TunnelKind.Mihomo, Ipv4Index: null, Ipv6Index: 23)
};
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 17, Ipv6: 23),
        ipv4MihomoIpv6Physical) == TunnelKind.Split &&
        ProxyProbeService.ClassifyRoutedAdapterEvidence(
            new BestRouteInterfaceIndexes(Ipv4: 17, Ipv6: 23),
            ipv4PhysicalIpv6Mihomo) == TunnelKind.Split,
    "Either IPv4 or IPv6 bypassing Mihomo must downgrade the dual-stack path instead of hiding a leak.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(Ipv4: 17, Ipv6: null),
        ipv4MihomoIpv6Physical) == TunnelKind.Mihomo,
    "An unavailable address family must not downgrade the only usable family.");
Require(ProxyProbeService.ClassifyRoutedAdapterEvidence(
        new BestRouteInterfaceIndexes(
            Ipv4: 17,
            Ipv6: null,
            Ipv4Unknown: false,
            Ipv6Unknown: true),
        ipv4MihomoIpv6Physical) == TunnelKind.Split &&
        ProxyProbeService.ClassifyRoutedAdapterEvidence(
            new BestRouteInterfaceIndexes(
                Ipv4: null,
                Ipv6: null,
                Ipv4Unknown: true,
                Ipv6Unknown: false),
            []) == TunnelKind.Unknown,
    "A failed best-route query must fail closed instead of being treated as an unavailable address family.");
Require(ProxyProbeService.InterpretBestRouteResult(0, 17) == BestRouteLookup.Resolved(17) &&
        ProxyProbeService.InterpretBestRouteResult(50, 0) == BestRouteLookup.Unavailable() &&
        ProxyProbeService.InterpretBestRouteResult(1003, 0) == BestRouteLookup.Failed() &&
        ProxyProbeService.InterpretBestRouteResult(1231, 0) == BestRouteLookup.Failed(),
    "Only ERROR_NOT_SUPPORTED may prove an address family unavailable; query failure or one unreachable target must remain unknown.");
Require(ProxyProbeService.AggregateBestRouteLookups(
            [BestRouteLookup.Resolved(17), BestRouteLookup.Resolved(17)]) ==
        BestRouteLookup.Resolved(17) &&
        ProxyProbeService.AggregateBestRouteLookups(
            [BestRouteLookup.Unavailable(), BestRouteLookup.Unavailable()]) ==
        BestRouteLookup.Unavailable(),
    "Only unanimous representative destinations may resolve or prove a family unavailable.");
var withinFamilySplit = ProxyProbeService.AggregateBestRouteLookups(
    [BestRouteLookup.Resolved(17), BestRouteLookup.Resolved(31)]);
var vpnAdapters = new[]
{
    new RoutedAdapterEvidence(TunnelKind.Other, 47, 47, "iKuuuVPN"),
    new RoutedAdapterEvidence(TunnelKind.None, 13, 13)
};
var splitVpn = ProxyProbeService.AnalyzeRoutes(
    [BestRouteLookup.Resolved(47), BestRouteLookup.Resolved(13)],
    [BestRouteLookup.Unavailable()], vpnAdapters);
Require(splitVpn.OtherTunnelDetected && splitVpn.Coverage == TunnelKind.Split && !splitVpn.MihomoDetected,
    "Within-family split routing must retain the confirmed third-party VPN interface.");
var partialVpn = ProxyProbeService.AnalyzeRoutes(
    [BestRouteLookup.Resolved(47), BestRouteLookup.Failed()],
    [BestRouteLookup.Unavailable()], vpnAdapters);
Require(partialVpn.OtherTunnelDetected && partialVpn.LookupUnknown,
    "A failed route query must not discard the VPN evidence from successful queries.");
var idleVpn = ProxyProbeService.AnalyzeRoutes(
    [BestRouteLookup.Resolved(13)], [BestRouteLookup.Resolved(13)], vpnAdapters);
Require(!idleVpn.OtherTunnelDetected && idleVpn.Coverage == TunnelKind.None,
    "An idle VPN adapter must not become proof of an active VPN path.");
var crossFamilyVpn = ProxyProbeService.AnalyzeRoutes(
    [BestRouteLookup.Resolved(47)], [BestRouteLookup.Resolved(13)], vpnAdapters);
Require(crossFamilyVpn.OtherTunnelDetected && crossFamilyVpn.Coverage == TunnelKind.Split,
    "IPv4 VPN with IPv6 physical routing must retain both VPN presence and incomplete coverage.");
var vpnSnapshot = ProxyProbeService.CreateSnapshot(new AppConfig { MixedPort = 7897 }, 0,
    TcpListenerAttribution.Closed, ProxyProbeService.ParseSystemProxyConfiguration(0, null, null), splitVpn);
Require(vpnSnapshot.OtherTunnelDetected && vpnSnapshot.VirtualNetworkDetected &&
        vpnSnapshot.DetectedClientName == "iKuuuVPN" && vpnSnapshot.ConnectionLabel == "VPN 已检测" &&
        vpnSnapshot.ConnectionSummary?.Contains("分流") == true &&
        vpnSnapshot.Port.Level != HealthLevel.Error && vpnSnapshot.Core.Level != HealthLevel.Error &&
        HealthCheckService.SelectPrimaryExitRoute(vpnSnapshot) == HealthExitRoute.SystemRoute,
    "iKuuu split routing and a stale closed Mihomo port must still expose the real system VPN path.");
var splitMihomo = ProxyProbeService.CreateSnapshot(new AppConfig(), 1, TcpListenerAttribution.Closed,
    ProxyProbeService.ParseSystemProxyConfiguration(0, null, null),
    new RouteDetection(TunnelKind.Split, true, false));
Require(!HealthCheckService.ShouldUseTunOnlySystemRoute(splitMihomo) &&
        HealthCheckService.SelectPrimaryExitRoute(splitMihomo) == HealthExitRoute.SystemRoute &&
        !splitMihomo.Port.Detail.Contains("已确认 Mihomo 代表性 TUN 路由", StringComparison.Ordinal),
    "Retaining partial Mihomo evidence must not upgrade it into a fully confirmed TUN-only path.");
var singleTargetHijack = ProxyProbeService.AggregateBestRouteLookups(
    [
        BestRouteLookup.Resolved(17),
        BestRouteLookup.Resolved(31),
        BestRouteLookup.Resolved(31),
        BestRouteLookup.Resolved(31)
    ]);
Require(withinFamilySplit == BestRouteLookup.Inconsistent() &&
        singleTargetHijack == BestRouteLookup.Inconsistent() &&
        ProxyProbeService.AggregateBestRouteLookups(
            [BestRouteLookup.Resolved(17), BestRouteLookup.Unavailable()]) ==
        BestRouteLookup.Inconsistent() &&
        ProxyProbeService.ClassifyRoutedAdapterEvidence(
            new BestRouteInterfaceIndexes(
                Ipv4: null,
                Ipv6: null,
                Ipv4Split: singleTargetHijack.Split),
            []) == TunnelKind.Split,
    "Within-family interface divergence, including one diverted target, must be reported as split routing.");
Require(ProxyProbeService.AggregateBestRouteLookups(
            [BestRouteLookup.Resolved(17), BestRouteLookup.Failed()]) ==
        BestRouteLookup.Failed() &&
        ProxyProbeService.AggregateBestRouteLookups(
            [BestRouteLookup.Failed(), BestRouteLookup.Unavailable()]) ==
        BestRouteLookup.Failed(),
    "One failed native lookup must remain unknown instead of being mistaken for unavailable or split routing.");
Require(ProxyProbeService.InterfaceCarriesBestRoute(
        ipv4Index: 17,
        ipv6Index: 23,
        bestRoutes: new BestRouteInterfaceIndexes(Ipv4: 31, Ipv6: 23)) &&
        !ProxyProbeService.InterfaceCarriesBestRoute(
            ipv4Index: 17,
            ipv6Index: 23,
            bestRoutes: new BestRouteInterfaceIndexes(Ipv4: 31, Ipv6: 42)),
    "IPv4 and IPv6 best-route indexes must both participate in adapter attribution.");
Require(ProxyProbeService.CombineAdapterKinds(
        [TunnelKind.Mihomo, TunnelKind.Other]) == TunnelKind.Other,
    "A concurrently active non-Mihomo VPN must not be hidden by a Mihomo adapter.");
var splitTunnelRoute = ProxyProbeService.DescribeSplitTunnelRoute();
Require(splitTunnelRoute.Level == HealthLevel.Warning &&
        splitTunnelRoute.Title == "路由分流" &&
        splitTunnelRoute.Value == "路径不一致",
    "A split route within or across address families must be visible as a warning.");
Require(ProxyProbeService.DescribeUnknownRoute().Level == HealthLevel.Warning,
    "An indeterminate native route lookup must remain a warning.");
var otherTunnelFallback = ProxyProbeService.DescribeDetectedSystemRoute(
    routeActive: true,
    systemProxyEnabled: false,
    otherTunnelDetected: true,
    routeDetail: "test");
Require(otherTunnelFallback?.Headline == "检测到其他 VPN/TUN",
    "An active third-party VPN must remain a warning instead of becoming a disconnected error when Mihomo is absent.");
var splitTunnelFallback = ProxyProbeService.DescribeDetectedSystemRoute(
    routeActive: true,
    systemProxyEnabled: false,
    otherTunnelDetected: false,
    routeDetail: "test",
    splitTunnelDetected: true);
Require(splitTunnelFallback?.Headline == "系统路由存在分流",
    "A partially bypassed route must not be reported as fully connected.");
var unknownRouteFallback = ProxyProbeService.DescribeDetectedSystemRoute(
    routeActive: true,
    systemProxyEnabled: false,
    otherTunnelDetected: false,
    routeDetail: "test",
    routeLookupUnknown: true);
Require(unknownRouteFallback?.Headline == "系统路由状态无法确认",
    "A failed native route query must not be reported as a confirmed path.");
var systemProxyFallback = ProxyProbeService.DescribeDetectedSystemRoute(
    routeActive: true,
    systemProxyEnabled: true,
    otherTunnelDetected: false,
    routeDetail: "test");
Require(systemProxyFallback?.Headline == "检测到系统代理路径",
    "An active proxy from another client must remain visible when the configured Mihomo port is unavailable.");
var systemProxyStatus = MainViewModel.BuildConnectionStatus(
    true, false, false, true, HealthLevel.Error, "ignored");
var virtualAdapterStatus = MainViewModel.BuildConnectionStatus(
    false, true, false, true, HealthLevel.Warning, "ignored");
var combinedStatus = MainViewModel.BuildConnectionStatus(
    true, true, false, true, HealthLevel.Ok, "ignored");
var directStatus = MainViewModel.BuildConnectionStatus(
    false, false, false, true, HealthLevel.Error, "ignored");
var offlineStatus = MainViewModel.BuildConnectionStatus(
    true, true, true, true, HealthLevel.Ok, "ignored");
Require(systemProxyStatus == ("系统代理", HealthLevel.Ok) &&
        virtualAdapterStatus == ("虚拟网卡", HealthLevel.Ok) &&
        combinedStatus == ("系统代理 + 虚拟网卡", HealthLevel.Warning) &&
        directStatus == ("未检测到代理", HealthLevel.Idle) &&
        offlineStatus == ("无网络连接", HealthLevel.Error),
    "The connection card must distinguish system proxy, virtual adapter, dual path, direct network, and no network.");
Require(MainViewModel.BuildConnectionClientDetail(
            @"C:\Program Files\v2rayN\v2rayN.exe", null, false, true, false, true) == "v2rayN" &&
        MainViewModel.BuildConnectionClientDetail(
            null, null, false, true, false, true) == "其他 VPN 已连接" &&
        MainViewModel.BuildConnectionClientDetail(
            null, null, true, false, false, true) == "其他系统代理已启用" &&
        MainViewModel.BuildConnectionClientDetail(
            null, null, true, true, false, true) == "其他 VPN / 代理已连接" &&
        MainViewModel.BuildConnectionClientDetail(
            @"C:\Program Files\Clash Verge\verge-mihomo.exe", "Clash Verge Rev",
            false, false, false, true) == "当前使用直连网络" &&
        MainViewModel.BuildConnectionClientDetail(
            null, null, true, true, true, true) == "请检查网络连接",
    "The connection subtitle must name one active client and use neutral fallbacks without stale attribution.");
Require(ProxyProbeService.DetectClientName(["v2rayN", "unrelated"]) == "v2rayN" &&
        ProxyProbeService.DetectClientName(["Clash Verge", "v2rayN"]) is null &&
        ProxyProbeService.DetectClientName(["Wintun Userspace Tunnel", "iKuuu VPN"]) == "iKuuuVPN",
    "Client detection must support common Windows clients and fail closed when attribution is ambiguous.");
Require(new ConnectionDiscoveryResult(
        false,
        "127.0.0.1",
        7890,
        "未发现代理核心",
        "test",
        false,
        false,
        true).TrafficMode == "其他 VPN/TUN",
    "Connection discovery must preserve a third-party VPN when no Mihomo port is available.");
Require(!ConnectionDiscoveryService.ShouldAcceptCandidate(
            isExplicitSystemProxy: false,
            TcpListenerAttribution.OtherOrUnknown) &&
        ConnectionDiscoveryService.ShouldAcceptCandidate(
            isExplicitSystemProxy: true,
            TcpListenerAttribution.OtherOrUnknown) &&
        !ConnectionDiscoveryService.ShouldAcceptCandidate(
            isExplicitSystemProxy: true,
            TcpListenerAttribution.Closed),
    "Configured and common ports require Mihomo PID ownership; only a listening explicit system proxy may remain as an unattributed local proxy.");
var unattributedSystemProxyDiscovery = new ConnectionDiscoveryResult(
    Found: true,
    Host: "127.0.0.1",
    Port: 7890,
    ClientName: "本地代理（未归属 Mihomo）",
    Source: "Windows 系统代理",
    SystemProxyEnabled: true,
    TunDetected: false,
    OtherTunnelDetected: false,
    EndpointOwnershipChecked: true,
    EndpointOwnedByMihomo: false);
Require(unattributedSystemProxyDiscovery.RouteWarning?.Contains("不会将它归因于 Mihomo", StringComparison.Ordinal) == true &&
        !unattributedSystemProxyDiscovery.ClientName.StartsWith("Mihomo", StringComparison.Ordinal),
    "A reachable explicit system proxy owned by another process must stay visible without Mihomo attribution.");
var tunOnlyDiscovery = new ConnectionDiscoveryResult(
    Found: false,
    Host: "127.0.0.1",
    Port: 7890,
    ClientName: "Mihomo / Clash Verge",
    Source: "test",
    SystemProxyEnabled: false,
    TunDetected: true,
    OtherTunnelDetected: false);
Require(tunOnlyDiscovery.TrafficMode == "TUN" && tunOnlyDiscovery.RouteWarning is null,
    "A confirmed TUN-only route must remain visible when no mixed endpoint is found.");
var foundSplitDiscovery = new ConnectionDiscoveryResult(
    Found: true,
    Host: "::1",
    Port: 7890,
    ClientName: "Mihomo",
    Source: "test",
    SystemProxyEnabled: false,
    TunDetected: false,
    OtherTunnelDetected: false,
    SplitTunnelDetected: true);
var missingSplitDiscovery = foundSplitDiscovery with { Found = false };
Require(foundSplitDiscovery.Endpoint == "[::1]:7890" &&
        foundSplitDiscovery.TrafficMode.Contains("分流", StringComparison.Ordinal) &&
        foundSplitDiscovery.RouteWarning?.Contains("直连泄漏", StringComparison.Ordinal) == true &&
        missingSplitDiscovery.RouteWarning == foundSplitDiscovery.RouteWarning,
    "Found and missing mixed endpoints must both preserve the split-route leak warning.");
var foundVirtualDiscovery = new ConnectionDiscoveryResult(
    Found: true,
    Host: "127.0.0.1",
    Port: 7890,
    ClientName: "local",
    Source: "test",
    SystemProxyEnabled: false,
    TunDetected: false,
    OtherTunnelDetected: false,
    VirtualNetworkDetected: true);
var missingVirtualDiscovery = foundVirtualDiscovery with { Found = false };
Require(foundVirtualDiscovery.TrafficMode == "虚拟网络路径" &&
        foundVirtualDiscovery.RouteWarning?.Contains("不能判定为 VPN/TUN", StringComparison.Ordinal) == true &&
        missingVirtualDiscovery.RouteWarning == foundVirtualDiscovery.RouteWarning,
    "Found and missing mixed endpoints must both preserve virtual-network attribution without calling it a VPN.");
var unknownRouteDiscovery = foundVirtualDiscovery with
{
    VirtualNetworkDetected = false,
    RouteLookupUnknown = true
};
Require(unknownRouteDiscovery.TrafficMode == "路由状态无法确认" &&
        unknownRouteDiscovery.RouteWarning is not null,
    "Connection discovery must preserve an indeterminate native route lookup.");
Require(ConnectionDiscoveryService.FallbackMixedPorts.SequenceEqual([7890, 7897]) &&
        !ConnectionDiscoveryService.FallbackMixedPorts.Contains(1080),
    "The SOCKS-only convention port 1080 must not be guessed as a Mihomo mixed port.");
using (var preCancelledTunnelProbe = new CancellationTokenSource())
{
    preCancelledTunnelProbe.Cancel();
    try
    {
        _ = await new ProxyProbeService().DetectTunAsync(preCancelledTunnelProbe.Token);
        throw new InvalidOperationException("A pre-cancelled tunnel probe must not query IP Helper.");
    }
    catch (OperationCanceledException)
    {
        // Expected before adapter enumeration or IP Helper route lookup.
    }
}
if (OperatingSystem.IsWindows())
{
    using (var ownershipListener = new TcpListener(IPAddress.Loopback, 0))
    {
        ownershipListener.Start();
        var ownershipPort = ((IPEndPoint)ownershipListener.LocalEndpoint).Port;
        Require(TcpListenerOwnership.IsOwnedByAny(
                "127.0.0.1",
                ownershipPort,
                new HashSet<int> { Environment.ProcessId }),
            "GetExtendedTcpTable must attribute a real loopback listener to the current Windows test PID.");
        Require(!TcpListenerOwnership.IsOwnedByAny(
                "127.0.0.1",
                ownershipPort,
                new HashSet<int> { 0 }),
            "The same real loopback listener must reject a non-owning PID.");
        var ipv4AcceptTask = ownershipListener.AcceptTcpClientAsync();
        var ipv4ProbeResult = await TcpListenerOwnership.ProbeAsync(
                "127.0.0.1",
                ownershipPort,
                new HashSet<int> { Environment.ProcessId },
                2);
        using var ipv4AcceptedClient = await ipv4AcceptTask.WaitAsync(TimeSpan.FromSeconds(2));
        Require(ipv4ProbeResult == TcpListenerAttribution.MihomoOwned,
            "The connected ownership probe must preserve IPv4 listener attribution.");
    }
    if (Socket.OSSupportsIPv6)
    {
        using (var ipv6OwnershipListener = new TcpListener(IPAddress.IPv6Loopback, 0))
        {
            ipv6OwnershipListener.Start();
            var ipv6OwnershipPort = ((IPEndPoint)ipv6OwnershipListener.LocalEndpoint).Port;
            Require(TcpListenerOwnership.IsOwnedByAny(
                    "::1",
                    ipv6OwnershipPort,
                    new HashSet<int> { Environment.ProcessId }),
                "GetExtendedTcpTable must attribute a real IPv6 loopback listener to the current Windows test PID.");
            Require(!TcpListenerOwnership.IsOwnedByAny(
                    "::1",
                    ipv6OwnershipPort,
                    new HashSet<int> { 0 }),
                "The real IPv6 loopback listener must reject a non-owning PID.");
            var ipv6AcceptTask = ipv6OwnershipListener.AcceptTcpClientAsync();
            var ipv6ProbeResult = await TcpListenerOwnership.ProbeAsync(
                    "::1",
                    ipv6OwnershipPort,
                    new HashSet<int> { Environment.ProcessId },
                    2);
            using var ipv6AcceptedClient = await ipv6AcceptTask.WaitAsync(TimeSpan.FromSeconds(2));
            Require(ipv6ProbeResult == TcpListenerAttribution.MihomoOwned,
                "The connected ownership probe must preserve IPv6 listener attribution.");
        }

        using (var dualModeListener = new TcpListener(IPAddress.IPv6Any, 0))
        {
            dualModeListener.Server.DualMode = true;
            dualModeListener.Start();
            var dualModePort = ((IPEndPoint)dualModeListener.LocalEndpoint).Port;
            var dualModeAcceptTask = dualModeListener.AcceptTcpClientAsync();
            var dualModeProbeResult = await TcpListenerOwnership.ProbeAsync(
                    "127.0.0.1",
                    dualModePort,
                    new HashSet<int> { Environment.ProcessId },
                    2);
            using var dualModeAcceptedClient = await dualModeAcceptTask.WaitAsync(TimeSpan.FromSeconds(2));
            Require(dualModeProbeResult == TcpListenerAttribution.MihomoOwned,
                "An IPv4 connection accepted by an IPv6 dual-mode listener must resolve through the exact connected tuple.");
            var dualModeNegativeAcceptTask = dualModeListener.AcceptTcpClientAsync();
            var dualModeNegativeProbeResult = await TcpListenerOwnership.ProbeAsync(
                    "127.0.0.1",
                    dualModePort,
                    new HashSet<int> { 0 },
                    2);
            using var dualModeNegativeAcceptedClient = await dualModeNegativeAcceptTask.WaitAsync(
                TimeSpan.FromSeconds(2));
            Require(dualModeNegativeProbeResult == TcpListenerAttribution.OtherOrUnknown,
                "The dual-mode connected tuple must reject a non-owning PID.");
        }
    }
    Require(ProxyProbeService.TryGetBestRouteInterfaceIndex(
            IPAddress.Loopback,
            out var loopbackInterfaceIndex) && loopbackInterfaceIndex > 0,
        "The native best-route query must resolve a local route without sending network traffic.");
    var routeChangeMonitor = new RouteChangeMonitor(() => { });
    Require(routeChangeMonitor.Start() && routeChangeMonitor.IsStarted,
        "The Windows route monitor must register without opening a GUI or network connection.");
    routeChangeMonitor.Dispose();
    Require(!routeChangeMonitor.IsStarted && !routeChangeMonitor.Start(),
        "Disposal must cancel the native route notification and prevent registration reuse.");
    routeChangeMonitor.Dispose();
}
Require(HealthCheckService.CalculateOverallTimeout(3) == TimeSpan.FromSeconds(30) &&
        HealthCheckService.CalculateOverallTimeout(30) == TimeSpan.FromSeconds(165) &&
        HealthCheckService.CalculateOverallTimeout(300) == TimeSpan.FromSeconds(165),
    "Windows health checks must have a bounded overall deadline derived from the supported timeout.");

var enabledGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t8\tOWNED\0");
var automaticGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t17\tOWNED\tAUTO\tC:\\Clash\\mihomo.exe\tCHOOSE\0");
Require(automaticGuard.IsHealthy && automaticGuard.AutomaticSelection && automaticGuard.SelectionRequired &&
        automaticGuard.ProxyExecutablePath == @"C:\Clash\mihomo.exe", "Extended status must expose the native core and selection mode.");
try { GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t17\tOWNED\tAUTO\t\\\\host\\mihomo.exe\tREADY"); throw new Exception("Unsafe status path accepted"); }
catch (GuardCommandException exception) when (exception.Code == "INVALID_RESPONSE") { }
Require(enabledGuard.Kind == GuardStatusKind.Enabled, "Healthy Guard filters must report enabled.");
Require(enabledGuard.OwnedByCurrentUser, "The enabling user must retain control of Guard.");
Require(enabledGuard.FilterCount == 8, "Guard status must preserve the WFP filter count.");
var foreignGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t6\tFOREIGN\0");
Require(!foreignGuard.OwnedByCurrentUser, "Other users must not be allowed to disable Guard.");
var faultedGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tFAULT\t2\tOWNED\0");
Require(faultedGuard.Kind == GuardStatusKind.Fault, "Incomplete persistent filters must fail visibly.");

var noSystemPathSnapshot = TestSnapshot(7890) with
{
    SystemProxyEnabled = false,
    TunDetected = false,
    Route = new MetricSnapshot(
        "流量入口",
        "未启用",
        "系统代理与 TUN 均未检测到",
        "入",
        HealthLevel.Idle)
};
var otherVpnSnapshot = noSystemPathSnapshot with
{
    OtherTunnelDetected = true,
    Route = new MetricSnapshot(
        "其他 VPN / TUN",
        "已检测",
        "系统路径由其他隧道承载",
        "入",
        HealthLevel.Warning)
};
Require(MainWindow.ShouldPromptForConnectionSetup(
        hasValidConfig: false,
        detectedSystemPath: false) &&
        !MainWindow.ShouldPromptForConnectionSetup(
            hasValidConfig: true,
            detectedSystemPath: false) &&
        !MainWindow.ShouldPromptForConnectionSetup(
            hasValidConfig: false,
            detectedSystemPath: true),
    "First launch must request a mixed endpoint only when both saved config and an active system path are absent.");
Require(!MainViewModel.HasDetectedSystemPath(noSystemPathSnapshot) &&
        MainViewModel.HasDetectedSystemPath(TestSnapshot(7890)) &&
        MainViewModel.HasDetectedSystemPath(noSystemPathSnapshot with { TunDetected = true }) &&
        MainViewModel.HasDetectedSystemPath(otherVpnSnapshot),
    "System proxy/PAC, Mihomo TUN, and other VPN/TUN paths must bypass forced first-run port setup.");

var pendingRefreshTimer = new System.Windows.Threading.DispatcherTimer();
pendingRefreshTimer.Start();
Require(MainWindow.StopPendingRefresh(pendingRefreshTimer) && !pendingRefreshTimer.IsEnabled,
    "A manual refresh or settings workflow must consume the pending debounce before starting I/O.");
Require(!MainWindow.StopPendingRefresh(pendingRefreshTimer),
    "Stopping an already-consumed debounce must not invent another pending refresh.");

var configTestDirectory = Path.Combine(
    Path.GetTempPath(),
    $"proxygauge-config-test.{Guid.NewGuid():N}");
var configPath = Path.Combine(configTestDirectory, "config.json");
try
{
    var configService = new ConfigService(configPath);
    Require(!configService.HasValidConfig, "A missing config must require setup.");

    Directory.CreateDirectory(configTestDirectory);
    File.WriteAllText(configPath, "{not-json");
    Require(!configService.HasValidConfig, "A corrupt config must require setup.");

    foreach (var invalidConfig in new[]
             {
                 "[]",
                 "{}",
                 "{} trailing-data",
                 "{\"MixedHost\":\"0.0.0.0\"}",
                 "{\"MixedPort\":0}",
                 "{\"MixedPort\":65536}",
                 "{\"TimeoutSeconds\":2}",
                 "{\"TimeoutSeconds\":31}",
                 "{\"ExpectedIp\":\"127.0.0.1\"}",
                 "{\"SecondaryMixedHost\":\"192.168.1.1\"}",
                 "{\"SecondaryMixedPort\":-1}",
                 "{\"SecondaryDomains\":\"not a domain\"}",
                 "{\"SecondaryLabel\":\"safe\\u202Etxt\"}",
                 "{\"UnknownSetting\":true}",
                 "{\"MixedPort\":7890,\"mixedport\":7891}"
             })
    {
        File.WriteAllText(configPath, invalidConfig);
        Require(!configService.HasValidConfig,
            $"Invalid persisted config must require setup: {invalidConfig}");
        Require(configService.Load().MixedPort == 7890,
            "An invalid persisted config must fall back to a clean in-memory default.");
    }

    File.WriteAllText(configPath, new string('x', (64 * 1024) + 1));
    Require(!configService.HasValidConfig,
        "An oversized config must be rejected before JSON deserialization.");

    configService.Save(new AppConfig
    {
        MixedHost = "localhost",
        MixedPort = 7788,
        TimeoutSeconds = 9
    });
    Require(configService.HasValidConfig, "A saved config must be valid.");
    var savedConfig = configService.Load();
    Require(savedConfig.MixedHost == "127.0.0.1", "Saved loopback hosts must normalize.");
    Require(savedConfig.MixedPort == 7788, "Saved ports must round-trip.");
    Require(savedConfig.TimeoutSeconds == 9, "Saved timeouts must round-trip.");
    Require(savedConfig.ProxyExecutablePath == string.Empty,
        "A new configuration must default to automatic Clash/Mihomo selection.");
    Require(!Directory.EnumerateFiles(configTestDirectory, "*.tmp").Any(),
        "Atomic saves must not leave temporary files behind.");

    var validConfigJson = File.ReadAllText(configPath);
    var legacyJson = System.Text.Json.Nodes.JsonNode.Parse(validConfigJson)!.AsObject();
    Require(legacyJson.Remove("ProxyExecutablePath"), "The new schema must persist the proxy selection.");
    File.WriteAllText(configPath, legacyJson.ToJsonString());
    Require(configService.HasValidConfig && configService.Load().ProxyExecutablePath == string.Empty,
        "Existing configs without a proxy selection must migrate to the default without losing settings.");
    savedConfig.ProxyExecutablePath = chosenCore;
    configService.Save(savedConfig);
    Require(configService.Load().ProxyExecutablePath == chosenCore,
        "An explicitly selected non-Clash executable must round-trip without needing to run during save.");
    File.WriteAllText(configPath, validConfigJson);
    var configMutations = new[]
    {
        validConfigJson.Replace("\"ProxyExecutablePath\": \"\"", "\"ProxyExecutablePath\": null"),
        validConfigJson.Replace("\"MixedHost\": \"127.0.0.1\"", "\"MixedHost\": \"0.0.0.0\""),
        validConfigJson.Replace("\"MixedPort\": 7788", "\"MixedPort\": 70000"),
        validConfigJson.Replace("\"TimeoutSeconds\": 9", "\"TimeoutSeconds\": 2"),
        validConfigJson.Replace("\"ExpectedIp\": \"\"", "\"ExpectedIp\": null"),
        validConfigJson.Replace(
            "\"SecondaryLabel\": \"Google / Gemini / Claude\"",
            "\"SecondaryLabel\": \"safe\\u202Etxt\""),
        validConfigJson.Replace(
            "\"SecondaryDomains\": \"gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com\"",
            "\"SecondaryDomains\": \"not a domain\""),
        validConfigJson.TrimEnd()[..^1] + ",\n  \"UnknownSetting\": true\n}",
        validConfigJson.TrimEnd()[..^1] + ",\n  \"mixedport\": 7789\n}",
        validConfigJson
            .Replace("  \"ExpectedIp\": \"\",\r\n", string.Empty)
            .Replace("  \"ExpectedIp\": \"\",\n", string.Empty)
    };
    Require(configMutations.All(mutation => mutation != validConfigJson),
        "The config mutation fixtures must each alter the known-good serialized schema.");
    foreach (var mutation in configMutations)
    {
        File.WriteAllText(configPath, mutation);
        Require(!configService.HasValidConfig,
            "A complete but semantically corrupted, ambiguous, or schema-drifted config must fail closed.");
    }
    File.WriteAllText(configPath, validConfigJson);
    Require(configService.HasValidConfig,
        "Restoring the exact known-good config must restore validity after mutation checks.");

    var originalJson = File.ReadAllText(configPath);
    var invalidSaveRejected = false;
    try
    {
        configService.Save(new AppConfig { MixedHost = "8.8.8.8", MixedPort = 70000 });
    }
    catch (InvalidDataException)
    {
        invalidSaveRejected = true;
    }
    Require(invalidSaveRejected && File.ReadAllText(configPath) == originalJson,
        "An invalid save must fail before replacing the last valid config.");
}
finally
{
    if (Directory.Exists(configTestDirectory))
    {
        Directory.Delete(configTestDirectory, recursive: true);
    }
}

var refreshTestDirectory = Path.Combine(
    Path.GetTempPath(),
    $"proxygauge-refresh-test.{Guid.NewGuid():N}");
try
{
    var refreshConfigService = new ConfigService(Path.Combine(refreshTestDirectory, "config.json"));
    refreshConfigService.Save(new AppConfig { MixedPort = 7890, TimeoutSeconds = 3 });
    var oldRequestStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var releaseOldRequest = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var resolverCalls = 0;
    var proxyProbe = new ProxyProbeService();
    var healthCheck = new HealthCheckService(
        proxyProbe,
        new MihomoPlanInspectionService(new MihomoControllerService()));
    using var viewModel = new MainViewModel(
        refreshConfigService,
        healthCheck,
        new GuardClient(),
        (config, _) => Task.FromResult(TestSnapshot(config.MixedPort)),
        async (config, _) =>
        {
            Interlocked.Increment(ref resolverCalls);
            if (config.MixedPort == 7890)
            {
                oldRequestStarted.TrySetResult(true);
                await releaseOldRequest.Task;
                return new ExitSummary("8.8.8.8", "United States");
            }
            return new ExitSummary("1.1.1.1", "Australia");
        },
        _ => Task.FromResult(GuardStatus.Unavailable()));

    var applyExit = typeof(MainViewModel).GetMethod(
        "ApplyExit",
        BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("The refresh race test could not locate ApplyExit.");
    applyExit.Invoke(viewModel, [new ExitSummary("9.9.9.9", "Switzerland")]);
    var firstRefresh = viewModel.RefreshAsync();
    Require(viewModel.ExitAddress == "正在检测" && !viewModel.HasExitIpVersion,
        "Starting a refresh must immediately invalidate the previously displayed exit IP.");
    await oldRequestStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));

    viewModel.SaveConfig(new AppConfig { MixedPort = 7891, TimeoutSeconds = 3 });
    Require(viewModel.ExitAddress == "等待重新检测",
        "Saving settings during a refresh must keep the stale IP invalidated.");
    _ = viewModel.RefreshAsync();
    releaseOldRequest.TrySetResult(true);
    await firstRefresh.WaitAsync(TimeSpan.FromSeconds(5));
    Require(resolverCalls >= 2 && viewModel.ExitAddress == "1.1.1.1" &&
            viewModel.Endpoint.EndsWith(":7891", StringComparison.Ordinal),
        "A canceled old-generation request must never overwrite the queued refresh for new settings.");

    applyExit.Invoke(viewModel, [new ExitSummary("8.8.8.8", "United States")]);
    viewModel.InvalidateExitSummary();
    Require(viewModel.ExitAddress == "等待重新检测" && !viewModel.HasExitIpVersion,
        "A network-change invalidation must clear the old address before the debounce elapses.");
}
finally
{
    if (Directory.Exists(refreshTestDirectory))
    {
        Directory.Delete(refreshTestDirectory, recursive: true);
    }
}

var failedProbeTestDirectory = Path.Combine(
    Path.GetTempPath(),
    $"proxygauge-failed-probe-test.{Guid.NewGuid():N}");
try
{
    var failedProbeConfig = new ConfigService(Path.Combine(failedProbeTestDirectory, "config.json"));
    failedProbeConfig.Save(new AppConfig { MixedPort = 7890, TimeoutSeconds = 3 });
    var failureMode = 0;
    var proxyProbe = new ProxyProbeService();
    using var viewModel = new MainViewModel(
        failedProbeConfig,
        new HealthCheckService(
            proxyProbe,
            new MihomoPlanInspectionService(new MihomoControllerService())),
        new GuardClient(),
        (config, _) => failureMode switch
        {
            1 => Task.FromException<ProxySnapshot>(new IOException("simulated probe failure")),
            2 => throw new IOException("simulated synchronous probe failure"),
            _ => Task.FromResult(TestSnapshot(config.MixedPort))
        },
        (_, _) => Task.FromResult(ExitSummary.Unavailable()),
        _ => Task.FromResult(GuardStatus.Unavailable()));

    await viewModel.RefreshAsync();
    Require(viewModel.Core.Level == HealthLevel.Ok && viewModel.Port.Level == HealthLevel.Ok,
        "The setup for the failed-probe regression must first publish healthy metrics.");
    failureMode = 1;
    await viewModel.RefreshAsync();
    Require(viewModel.Core.Level == HealthLevel.Error &&
            viewModel.Port.Level == HealthLevel.Error &&
            viewModel.Route.Level == HealthLevel.Error &&
            viewModel.Core.Value == "状态不可用" &&
            viewModel.Route.Value == "状态不可用",
        "A failed probe must clear previously healthy route metrics instead of leaving stale state visible.");
    failureMode = 2;
    await viewModel.RefreshAsync();
    Require(viewModel.Core.Level == HealthLevel.Error && viewModel.Route.Value == "状态不可用",
        "A synchronously thrown probe factory must be contained like an asynchronously failed probe.");
}
finally
{
    if (Directory.Exists(failedProbeTestDirectory))
    {
        Directory.Delete(failedProbeTestDirectory, recursive: true);
    }
}

var guardRefreshTestDirectory = Path.Combine(
    Path.GetTempPath(),
    $"proxygauge-guard-refresh-test.{Guid.NewGuid():N}");
try
{
    var guardRefreshConfig = new ConfigService(Path.Combine(guardRefreshTestDirectory, "config.json"));
    guardRefreshConfig.Save(new AppConfig { MixedPort = 7890, TimeoutSeconds = 3 });
    var probeCalls = 0;
    var proxyProbe = new ProxyProbeService();
    using var viewModel = new MainViewModel(
        guardRefreshConfig,
        new HealthCheckService(
            proxyProbe,
            new MihomoPlanInspectionService(new MihomoControllerService())),
        new GuardClient(),
        (config, _) =>
        {
            Interlocked.Increment(ref probeCalls);
            return Task.FromResult(TestSnapshot(config.MixedPort));
        },
        (_, _) => Task.FromResult(ExitSummary.Unavailable()),
        _ => Task.FromResult(GuardStatus.Unavailable()));

    var guardBusySetter = typeof(MainViewModel).GetProperty(nameof(MainViewModel.IsGuardBusy))?
        .GetSetMethod(nonPublic: true)
        ?? throw new InvalidOperationException("The guard concurrency test could not set IsGuardBusy.");
    var startRefreshLoop = typeof(MainViewModel).GetMethod(
        "StartRefreshLoopIfNeeded",
        BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("The guard concurrency test could not resume refreshes.");

    guardBusySetter.Invoke(viewModel, [true]);
    _ = viewModel.RefreshAsync();
    await Task.Delay(100);
    Require(probeCalls == 0 && !viewModel.IsNotBusy,
        "A refresh requested during a Guard mutation must remain queued and its button state disabled.");
    guardBusySetter.Invoke(viewModel, [false]);
    var queuedRefresh = (Task)startRefreshLoop.Invoke(viewModel, null)!;
    await queuedRefresh.WaitAsync(TimeSpan.FromSeconds(2));
    Require(probeCalls == 1,
        "A refresh queued during a Guard mutation must run after the mutation finishes.");
}
finally
{
    if (Directory.Exists(guardRefreshTestDirectory))
    {
        Directory.Delete(guardRefreshTestDirectory, recursive: true);
    }
}

var disposalTestDirectory = Path.Combine(
    Path.GetTempPath(),
    $"proxygauge-disposal-test.{Guid.NewGuid():N}");
try
{
    var disposalConfig = new ConfigService(Path.Combine(disposalTestDirectory, "config.json"));
    disposalConfig.Save(new AppConfig { MixedPort = 7890, TimeoutSeconds = 3 });
    var refreshStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var refreshCanceled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var proxyProbe = new ProxyProbeService();
    var viewModel = new MainViewModel(
        disposalConfig,
        new HealthCheckService(
            proxyProbe,
            new MihomoPlanInspectionService(new MihomoControllerService())),
        new GuardClient(),
        async (_, token) =>
        {
            refreshStarted.TrySetResult(true);
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return TestSnapshot(7890);
            }
            finally
            {
                if (token.IsCancellationRequested)
                {
                    refreshCanceled.TrySetResult(true);
                }
            }
        },
        (_, _) => Task.FromResult(new ExitSummary("8.8.8.8", "United States")),
        _ => Task.FromResult(GuardStatus.Unavailable()));
    var refreshTask = viewModel.RefreshAsync();
    await refreshStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
    viewModel.Dispose();
    await refreshCanceled.Task.WaitAsync(TimeSpan.FromSeconds(2));
    await refreshTask.WaitAsync(TimeSpan.FromSeconds(2));
    Require(viewModel.LastUpdated == "尚未刷新" && !viewModel.IsBusy,
        "Disposal must cancel a refresh and suppress all late snapshot publication.");

    var healthStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var healthCanceled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var healthViewModel = new MainViewModel(
        disposalConfig,
        new HealthCheckService(
            proxyProbe,
            new MihomoPlanInspectionService(new MihomoControllerService())),
        new GuardClient(),
        (_, _) => Task.FromResult(TestSnapshot(7890)),
        (_, _) => Task.FromResult(ExitSummary.Unavailable()),
        _ => Task.FromResult(GuardStatus.Unavailable()),
        async (_, token) =>
        {
            healthStarted.TrySetResult(true);
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                throw new InvalidOperationException("The canceled health task unexpectedly resumed.");
            }
            finally
            {
                if (token.IsCancellationRequested)
                {
                    healthCanceled.TrySetResult(true);
                }
            }
        });
    var healthTask = healthViewModel.RunHealthCheckAsync();
    await healthStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
    healthViewModel.Dispose();
    await healthCanceled.Task.WaitAsync(TimeSpan.FromSeconds(2));
    Require(await healthTask.WaitAsync(TimeSpan.FromSeconds(2)) is null &&
            !healthViewModel.IsBusy && !healthViewModel.IsHealthCheckRunning,
        "Disposal must cancel a long health check without queuing a replacement refresh.");
}
finally
{
    if (Directory.Exists(disposalTestDirectory))
    {
        Directory.Delete(disposalTestDirectory, recursive: true);
    }
}

var healthy = new HealthReport
{
    CheckedAt = DateTime.UtcNow,
    Sections =
    [
        new HealthCheckSection("local", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("boundary", [Item(HealthLevel.Ok)], 10)
    ]
};
Require(healthy.Score == 100, "A fully healthy report must score 100.");

var criticalFailure = new HealthReport
{
    CheckedAt = DateTime.UtcNow,
    Sections =
    [
        new HealthCheckSection("local", [Item(HealthLevel.Error)], 45, IsCritical: true),
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("boundary", [Item(HealthLevel.Ok)], 10)
    ]
};
Require(criticalFailure.Score == 49, "Critical failures must cap the score at 49.");

var nonCriticalFailure = new HealthReport
{
    CheckedAt = DateTime.UtcNow,
    Sections =
    [
        new HealthCheckSection("local", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("boundary", [Item(HealthLevel.Error)], 10)
    ]
};
Require(nonCriticalFailure.Score == 69, "Non-critical failures must cap the score at 69.");

Console.WriteLine("ProxyGauge Windows logic tests passed.");

sealed class StubHttpMessageHandler(
    Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> sendAsync)
    : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var response = await sendAsync(request, cancellationToken);
        response.RequestMessage ??= request;
        return response;
    }
}

sealed class CancellationOnlyStream : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw new OperationCanceledException(cancellationToken);
        }
        return 0;
    }

    public override Task<int> ReadAsync(
        byte[] buffer,
        int offset,
        int count,
        CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
