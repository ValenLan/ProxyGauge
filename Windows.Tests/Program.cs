using ProxyGauge.Models;
using ProxyGauge.Services;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static HealthCheckItem Item(HealthLevel level) => new("test", "test", level);

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
