namespace ProxyGauge.Models;

public sealed class AppConfig
{
    // Empty enables automatic known-core discovery; a custom choice pins an executable path.
    public string ProxyExecutablePath { get; set; } = string.Empty;
    public string MixedHost { get; set; } = "127.0.0.1";
    public int MixedPort { get; set; } = 7890;
    public string ExpectedIp { get; set; } = string.Empty;
    public int TimeoutSeconds { get; set; } = 6;
    public bool SecondaryEnabled { get; set; }
    public string SecondaryLabel { get; set; } = "Google / Gemini / Claude";
    public string SecondaryGroup { get; set; } = "Google-Chain";
    public string DefaultGroup { get; set; } = "PROXY";
    public string SecondaryMixedHost { get; set; } = "127.0.0.1";
    public int SecondaryMixedPort { get; set; } = 7891;
    public string SecondaryDomains { get; set; } =
        "gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com";
    public string ExpectedSecondaryIp { get; set; } = string.Empty;

    public AppConfig Clone() => new()
    {
        ProxyExecutablePath = ProxyExecutablePath,
        MixedHost = MixedHost,
        MixedPort = MixedPort,
        ExpectedIp = ExpectedIp,
        TimeoutSeconds = TimeoutSeconds,
        SecondaryEnabled = SecondaryEnabled,
        SecondaryLabel = SecondaryLabel,
        SecondaryGroup = SecondaryGroup,
        DefaultGroup = DefaultGroup,
        SecondaryMixedHost = SecondaryMixedHost,
        SecondaryMixedPort = SecondaryMixedPort,
        SecondaryDomains = SecondaryDomains,
        ExpectedSecondaryIp = ExpectedSecondaryIp
    };
}
