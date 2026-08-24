using System.IO;
using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public string ConfigPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ProxyGauge",
        "config.json");

    public bool HasSavedConfig => File.Exists(ConfigPath) || LegacyConfigPaths.Any(File.Exists);

    private IEnumerable<string> LegacyConfigPaths
    {
        get
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            yield return Path.Combine(appData, "CloudCheck", "config.json");
            yield return Path.Combine(appData, "CloudLinkGuard", "config.json");
            yield return Path.Combine(appData, "CloudRoute", "config.json");
            yield return Path.Combine(appData, "PuffRoute", "config.json");
        }
    }

    public AppConfig Load()
    {
        try
        {
            var sourcePath = File.Exists(ConfigPath)
                ? ConfigPath
                : LegacyConfigPaths.FirstOrDefault(File.Exists);
            if (sourcePath is null)
            {
                return new AppConfig();
            }

            var json = File.ReadAllText(sourcePath);
            var config = Normalize(JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig());
            if (sourcePath != ConfigPath && !File.Exists(ConfigPath))
            {
                Save(config);
            }
            return config;
        }
        catch
        {
            return new AppConfig();
        }
    }

    public void Save(AppConfig config)
    {
        var normalized = Normalize(config);
        var directory = Path.GetDirectoryName(ConfigPath)
            ?? throw new InvalidOperationException("无法确定配置目录。");
        Directory.CreateDirectory(directory);
        File.WriteAllText(ConfigPath, JsonSerializer.Serialize(normalized, JsonOptions));
    }

    private static AppConfig Normalize(AppConfig config)
    {
        config.MixedHost = LocalEndpointPolicy.NormalizeLoopbackHost(config.MixedHost);
        config.MixedPort = Math.Clamp(config.MixedPort, 1, 65535);
        config.ExpectedIp = config.ExpectedIp?.Trim() ?? string.Empty;
        config.TimeoutSeconds = Math.Clamp(config.TimeoutSeconds, 3, 30);
        config.SecondaryLabel = NormalizeText(config.SecondaryLabel, "额外出口");
        config.SecondaryGroup = NormalizeText(config.SecondaryGroup, "Google-Chain");
        config.DefaultGroup = NormalizeText(config.DefaultGroup, "PROXY");
        config.SecondaryMixedHost = LocalEndpointPolicy.NormalizeLoopbackHost(
            config.SecondaryMixedHost);
        config.SecondaryMixedPort = Math.Clamp(config.SecondaryMixedPort, 1, 65535);
        config.SecondaryDomains = config.SecondaryDomains?.Trim() ?? string.Empty;
        config.ExpectedSecondaryIp = config.ExpectedSecondaryIp?.Trim() ?? string.Empty;
        return config;
    }

    private static string NormalizeText(string? value, string fallback) =>
        string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
}
