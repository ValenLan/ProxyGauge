namespace PuffRoute.Models;

public enum HealthLevel
{
    Idle,
    Ok,
    Warning,
    Error
}

public sealed record MetricSnapshot(
    string Title,
    string Value,
    string Detail,
    string Marker,
    HealthLevel Level);

public sealed record ProxySnapshot(
    string Headline,
    string Detail,
    HealthLevel OverallLevel,
    MetricSnapshot Core,
    MetricSnapshot Port,
    MetricSnapshot Route,
    bool SystemProxyEnabled,
    bool TunDetected);
