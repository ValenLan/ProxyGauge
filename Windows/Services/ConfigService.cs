using System.Text.Json;
using PuffRoute.Models;

namespace PuffRoute.Services;

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public string ConfigPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "PuffRoute",
        "config.json");

    public AppConfig Load()
    {
        try
        {
            if (!File.Exists(ConfigPath))
            {
                return new AppConfig();
            }

            var json = File.ReadAllText(ConfigPath);
            return Normalize(JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig());
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
