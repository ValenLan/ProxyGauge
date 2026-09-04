using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class ConfigService
{
    private const int MaximumConfigBytes = 64 * 1024;
    private const int MaximumHostLength = 64;
    private const int MaximumIpLength = 64;
    private const int MaximumLabelLength = 128;
    private const int MaximumDomainsLength = 4096;
    private const int MaximumDomainCount = 128;

    private static readonly HashSet<string> KnownProperties = new(
    [
        nameof(AppConfig.ProxyExecutablePath),
        nameof(AppConfig.MixedHost),
        nameof(AppConfig.MixedPort),
        nameof(AppConfig.ExpectedIp),
        nameof(AppConfig.TimeoutSeconds),
        nameof(AppConfig.SecondaryEnabled),
        nameof(AppConfig.SecondaryLabel),
        nameof(AppConfig.SecondaryGroup),
        nameof(AppConfig.DefaultGroup),
        nameof(AppConfig.SecondaryMixedHost),
        nameof(AppConfig.SecondaryMixedPort),
        nameof(AppConfig.SecondaryDomains),
        nameof(AppConfig.ExpectedSecondaryIp)
    ], StringComparer.OrdinalIgnoreCase);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public ConfigService(string? configPath = null)
    {
        ConfigPath = configPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
#if PROXYGAUGE_TRIAL
            "ProxyGauge-Trial",
#else
            "ProxyGauge",
#endif
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

            var json = ReadConfigBytes(ConfigPath);
            var jsonOffset = GetJsonOffset(json);
            ValidateJsonShape(json, jsonOffset);
            var loaded = JsonSerializer.Deserialize<AppConfig>(
                json.AsSpan(jsonOffset),
                JsonOptions);
            if (loaded is null)
            {
                return false;
            }

            config = ValidateAndNormalize(loaded);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void Save(AppConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        var normalized = ValidateAndNormalize(config.Clone());
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

    private static byte[] ReadConfigBytes(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 4096,
            FileOptions.SequentialScan);
        if (stream.Length is <= 0 or > MaximumConfigBytes)
        {
            throw new InvalidDataException("配置文件大小无效。");
        }

        var content = new byte[checked((int)stream.Length)];
        stream.ReadExactly(content);
        if (stream.ReadByte() != -1)
        {
            throw new InvalidDataException("读取配置时文件发生变化。");
        }
        return content;
    }

    private static int GetJsonOffset(byte[] json) =>
        json.Length >= 3 && json[0] == 0xEF && json[1] == 0xBB && json[2] == 0xBF
            ? 3
            : 0;

    private static void ValidateJsonShape(byte[] json, int offset)
    {
        using var document = JsonDocument.Parse(
            json.AsMemory(offset),
            new JsonDocumentOptions { MaxDepth = 8 });
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("配置根节点必须是对象。");
        }

        var encountered = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            if (!KnownProperties.Contains(property.Name) || !encountered.Add(property.Name))
            {
                throw new InvalidDataException("配置包含未知或重复字段。");
            }
        }
        // Old configurations predate application selection and keep the Clash default.
        if (!KnownProperties.Where(name => name != nameof(AppConfig.ProxyExecutablePath))
                .All(encountered.Contains))
        {
            throw new InvalidDataException("配置缺少必需字段。");
        }
    }

    private static AppConfig ValidateAndNormalize(AppConfig config)
    {
        config.ProxyExecutablePath = ProxyApplicationSelection.NormalizePath(config.ProxyExecutablePath);
        if (!IsBounded(config.MixedHost, MaximumHostLength) ||
            !LocalEndpointPolicy.IsLoopbackHost(config.MixedHost))
        {
            throw new InvalidDataException("主入口地址必须是本机回环地址。");
        }
        if (config.MixedPort is < 1 or > 65535)
        {
            throw new InvalidDataException("主入口端口必须介于 1–65535。");
        }
        if (config.TimeoutSeconds is < 3 or > 30)
        {
            throw new InvalidDataException("超时时间必须介于 3–30 秒。");
        }

        config.MixedHost = LocalEndpointPolicy.NormalizeLoopbackHost(config.MixedHost);
        config.ExpectedIp = NormalizeOptionalPublicIp(config.ExpectedIp, "期望出口 IP");
        config.SecondaryLabel = NormalizeRequiredText(config.SecondaryLabel, "额外方案名称");
        config.SecondaryGroup = NormalizeRequiredText(config.SecondaryGroup, "额外策略组");
        config.DefaultGroup = NormalizeRequiredText(config.DefaultGroup, "默认策略组");

        if (!IsBounded(config.SecondaryMixedHost, MaximumHostLength) ||
            !LocalEndpointPolicy.IsLoopbackHost(config.SecondaryMixedHost))
        {
            throw new InvalidDataException("额外入口地址必须是本机回环地址。");
        }
        if (config.SecondaryMixedPort is < 1 or > 65535)
        {
            throw new InvalidDataException("额外入口端口必须介于 1–65535。");
        }
        config.SecondaryMixedHost = LocalEndpointPolicy.NormalizeLoopbackHost(
            config.SecondaryMixedHost);
        config.SecondaryDomains = NormalizeDomains(config.SecondaryDomains);
        config.ExpectedSecondaryIp = NormalizeOptionalPublicIp(
            config.ExpectedSecondaryIp,
            "额外出口期望 IP");
        return config;
    }

    private static string NormalizeRequiredText(string? value, string fieldName)
    {
        var normalized = value?.Trim() ?? string.Empty;
        if (normalized.Length == 0 || normalized.Length > MaximumLabelLength ||
            ContainsUnsafeCharacters(normalized))
        {
            throw new InvalidDataException($"{fieldName}无效。");
        }
        return normalized;
    }

    private static string NormalizeOptionalPublicIp(string? value, string fieldName)
    {
        if (value is null)
        {
            throw new InvalidDataException($"{fieldName}不能为 null。");
        }
        var normalized = value.Trim();
        if (normalized.Length == 0)
        {
            return string.Empty;
        }
        if (normalized.Length > MaximumIpLength ||
            !ExitSummary.TryNormalizePublicAddress(normalized, out var publicAddress))
        {
            throw new InvalidDataException($"{fieldName}必须是规范的公网 IPv4 或 IPv6。");
        }
        return publicAddress;
    }

    private static string NormalizeDomains(string? value)
    {
        var normalized = value?.Trim() ?? string.Empty;
        if (normalized.Length == 0 || normalized.Length > MaximumDomainsLength ||
            ContainsUnsafeCharacters(normalized))
        {
            throw new InvalidDataException("额外检测域名无效。");
        }

        var domains = normalized.Split(
            ',',
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (domains.Length is 0 or > MaximumDomainCount || domains.Any(domain =>
                domain.Length > 253 ||
                Uri.CheckHostName(domain) == UriHostNameType.Unknown))
        {
            throw new InvalidDataException("额外检测域名无效。");
        }
        return string.Join(',', domains);
    }

    private static bool IsBounded(string? value, int maximumLength) =>
        value is not null && value.Trim().Length is > 0 && value.Length <= maximumLength &&
        !ContainsUnsafeCharacters(value);

    private static bool ContainsUnsafeCharacters(string value)
    {
        for (var index = 0; index < value.Length; index++)
        {
            var category = CharUnicodeInfo.GetUnicodeCategory(value, index);
            if (category is UnicodeCategory.Control or
                UnicodeCategory.Format or
                UnicodeCategory.LineSeparator or
                UnicodeCategory.ParagraphSeparator or
                UnicodeCategory.Surrogate)
            {
                return true;
            }
            if (char.IsHighSurrogate(value[index]) &&
                index + 1 < value.Length && char.IsLowSurrogate(value[index + 1]))
            {
                index++;
            }
        }
        return false;
    }
}
