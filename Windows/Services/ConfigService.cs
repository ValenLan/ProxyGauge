using System.IO;
using System.Text;
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

    public ConfigService(string? configPath = null)
    {
        ConfigPath = configPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ProxyGauge",
            "config.json");
    }

    public string ConfigPath { get; }

    public bool HasValidConfig => TryLoad(out _);

    public AppConfig Load()
    {
        return TryLoad(out var config) ? config : new AppConfig();
    }

    public bool TryLoad(out AppConfig config)
    {
        config = new AppConfig();
        try
        {
            if (!File.Exists(ConfigPath))
            {
                return false;
            }

            var json = File.ReadAllText(ConfigPath);
            var loaded = JsonSerializer.Deserialize<AppConfig>(json);
            if (loaded is null)
            {
                return false;
            }

            config = Normalize(loaded);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void Save(AppConfig config)
    {
        var normalized = Normalize(config.Clone());
        var directory = Path.GetDirectoryName(ConfigPath)
            ?? throw new InvalidOperationException("无法确定配置目录。");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(ConfigPath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            var json = JsonSerializer.Serialize(normalized, JsonOptions);
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 4096,
                       options: FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                writer.Write(json);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            if (File.Exists(ConfigPath))
            {
                File.Replace(temporaryPath, ConfigPath, destinationBackupFileName: null);
            }
            else
            {
                File.Move(temporaryPath, ConfigPath);
            }
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
            catch
            {
                // A cleanup failure must not hide the original save result.
            }
        }
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
