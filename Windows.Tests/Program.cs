using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ProxyGauge;
using ProxyGauge.Models;
using ProxyGauge.Services;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static HealthCheckItem Item(HealthLevel level) => new("test", "test", level);

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

Require(UpdateService.CompareVersions("1.6.0", "1.5.7") > 0,
    "A newer semantic version must be detected.");
Require(UpdateService.CompareVersions("1.5.7", "1.5.7") == 0,
    "Equal semantic versions must not trigger an update.");
var checksum = new string('a', 64);
Require(UpdateService.FindChecksum($"{checksum}  ProxyGauge-1.6.0-win-x64.msi\n", "ProxyGauge-1.6.0-win-x64.msi") == checksum,
    "The updater must select the exact MSI checksum.");

var flatExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"203.0.113.8","is_datacenter":false,"is_proxy":false,"is_vpn":false,"company_name":"Example Network","asn_num":64500,"asn_org":"Example ASN","cc":"US"}""",
    """{"ip":"203.0.113.8","city":"Los Angeles","country":"US","country_name":"United States","asn":"AS64500","org":"Example ASN"}""");
Require(flatExitSummary is not null, "The current flat ipapi.is payload must produce an exit summary.");
Require(flatExitSummary!.Location == "United States · Los Angeles",
    "The secondary location response must enrich the flat anonymous payload.");
Require(flatExitSummary.Network == "AS64500 · Example ASN",
    "The current flat ASN fields must remain visible.");
Require(flatExitSummary.NetworkType == "IP 类型未知",
    "Negative risk flags alone must not be presented as an IP type.");

var ispExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"203.0.113.8","is_datacenter":false,"is_proxy":false,"is_vpn":false,"company":{"name":"Example Network","type":"isp"},"asn":{"asn":64500,"org":"Example ASN","type":"isp"},"location":{"country":"United States","city":"Los Angeles"}}""");
Require(ispExitSummary?.NetworkType == "ISP 网络",
    "An explicit ISP classification must be shown as the IP type.");

var vpnExitSummary = ExitSummaryService.ParseResponse(
    """{"ip":"203.0.113.8","is_vpn":true,"company":{"type":"isp"},"asn":{"type":"isp"}}""");
Require(vpnExitSummary?.NetworkType == "VPN 出口",
    "A positive VPN signal must take priority over the network owner's ISP category.");

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
        var locationChip = (TextBlock)mainWindow.FindName("ExitLocationChip");
        var typeChip = (TextBlock)mainWindow.FindName("ExitNetworkTypeChip");
        Require(locationChip.GetBindingExpression(TextBlock.TextProperty)?.ParentBinding.Path.Path == "ExitLocation",
            "The first exit chip must display the country/region value.");
        Require(typeChip.GetBindingExpression(TextBlock.TextProperty)?.ParentBinding.Path.Path == "ExitNetworkType",
            "The second exit chip must display the verified IP type.");
        var lightPixels = RenderPixels(mainRoot, 820, 550, Artifact("main-light.png"));
        Require(RequireSolidColor(mainRoot.Background,
                    "The main window root must use a solid canvas brush in light mode.") == Colors.White,
            "The already-created main window must resolve the light canvas to white.");
        Require(CountExactColor(lightPixels, Colors.White) > 200_000,
            "The Windows-rendered light dashboard must contain its white canvas and surfaces.");

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
        settingsWindow = new SettingsWindow(
            new AppConfig(),
            discoveryService,
            updateService);
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
Require(LocalEndpointPolicy.NormalizeLoopbackHost("192.0.2.1") == "127.0.0.1",
    "Invalid saved hosts must fail closed to the local default.");

var enabledGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t8\tOWNED\0");
Require(enabledGuard.Kind == GuardStatusKind.Enabled, "Healthy Guard filters must report enabled.");
Require(enabledGuard.OwnedByCurrentUser, "The enabling user must retain control of Guard.");
Require(enabledGuard.FilterCount == 8, "Guard status must preserve the WFP filter count.");
var foreignGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tHEALTHY\t6\tFOREIGN\0");
Require(!foreignGuard.OwnedByCurrentUser, "Other users must not be allowed to disable Guard.");
var faultedGuard = GuardProtocol.ParseStatus("OK\tSTATUS\tENABLED\tFAULT\t2\tOWNED\0");
Require(faultedGuard.Kind == GuardStatusKind.Fault, "Incomplete persistent filters must fail visibly.");

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
    Require(!Directory.EnumerateFiles(configTestDirectory, "*.tmp").Any(),
        "Atomic saves must not leave temporary files behind.");
}
finally
{
    if (Directory.Exists(configTestDirectory))
    {
        Directory.Delete(configTestDirectory, recursive: true);
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
