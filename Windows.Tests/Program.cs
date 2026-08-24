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

var healthy = new HealthReport
{
    CheckedAt = DateTime.UtcNow,
    Sections =
    [
        new HealthCheckSection("local", [Item(HealthLevel.Ok)], 45, IsCritical: true),
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 30, IsCritical: true),
        new HealthCheckSection("risk", [Item(HealthLevel.Ok)], 15),
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
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 30, IsCritical: true),
        new HealthCheckSection("risk", [Item(HealthLevel.Ok)], 15),
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
        new HealthCheckSection("exit", [Item(HealthLevel.Ok)], 30, IsCritical: true),
        new HealthCheckSection("risk", [Item(HealthLevel.Error)], 15),
        new HealthCheckSection("boundary", [Item(HealthLevel.Ok)], 10)
    ]
};
Require(nonCriticalFailure.Score == 69, "Non-critical failures must cap the score at 69.");

Console.WriteLine("ProxyGauge Windows logic tests passed.");
