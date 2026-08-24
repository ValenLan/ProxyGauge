namespace ProxyGauge.Models;

public sealed record BrowserLaunchResult(
    bool Started,
    string Message,
    string BrowserName = "",
    string RouteLabel = "");
