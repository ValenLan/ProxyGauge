using System.IO;
using System.Text.Json;
using CloudLinkGuard.Models;

namespace CloudLinkGuard.Services;

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public string ConfigPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CloudLinkGuard",
        "config.json");

    private IEnumerable<string> LegacyConfigPaths
    {
        get
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
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
        config.MixedHost = string.IsNullOrWhiteSpace(config.MixedHost)
            ? "127.0.0.1"
            : config.MixedHost.Trim();
        config.MixedPort = Math.Clamp(config.MixedPort, 1, 65535);
        config.ExpectedIp = config.ExpectedIp.Trim();
        config.TimeoutSeconds = Math.Clamp(config.TimeoutSeconds, 3, 30);
        return config;
    }
}
