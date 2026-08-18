namespace CloudRoute.Models;

public sealed class AppConfig
{
    public string MixedHost { get; set; } = "127.0.0.1";
    public int MixedPort { get; set; } = 7890;
    public string ExpectedIp { get; set; } = string.Empty;
    public int TimeoutSeconds { get; set; } = 6;

    public AppConfig Clone() => new()
    {
        MixedHost = MixedHost,
        MixedPort = MixedPort,
        ExpectedIp = ExpectedIp,
        TimeoutSeconds = TimeoutSeconds
    };
}
