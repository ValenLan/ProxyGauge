using System.IO;
using System.Text.Json;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

internal sealed record ExitSummaryStoreState(string? PathFingerprint, ExitSummary? Summary);

internal sealed class ExitSummaryStore
{
    private const int CurrentVersion = 1;
    private const int MaximumBytes = 4096;
    private const int MaximumLocationLength = 160;
    private readonly string _path;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private sealed record Payload(
        int Version,
        string? PathFingerprint,
        string? Address,
        string? Location);

    public ExitSummaryStore(string configPath)
    {
        var directory = Path.GetDirectoryName(configPath)
            ?? throw new ArgumentException("配置路径缺少父目录。", nameof(configPath));
        _path = Path.Combine(directory, "exit-summary.json");
    }

    public ExitSummaryStoreState Load()
    {
        try
        {
            if (!File.Exists(_path)) return new ExitSummaryStoreState(null, null);
            var info = new FileInfo(_path);
            if (info.Length is <= 0 or > MaximumBytes) return new ExitSummaryStoreState(null, null);
            var payload = JsonSerializer.Deserialize<Payload>(File.ReadAllBytes(_path), JsonOptions);
            if (payload?.Version != CurrentVersion) return new ExitSummaryStoreState(null, null);
            var fingerprint = IsFingerprint(payload.PathFingerprint) ? payload.PathFingerprint : null;
            var summary = ExitSummary.TryNormalizePublicAddress(payload.Address, out var address) &&
                          IsSafeLocation(payload.Location)
                ? new ExitSummary(address, payload.Location!)
                : null;
            return new ExitSummaryStoreState(fingerprint, summary);
        }
        catch
        {
            return new ExitSummaryStoreState(null, null);
        }
    }

    public void RecordPathFingerprint(string fingerprint, bool clearSummary)
    {
        if (!IsFingerprint(fingerprint)) return;
        var current = Load();
        var summary = clearSummary ? null : current.Summary;
        Write(new Payload(CurrentVersion, fingerprint, summary?.Address, summary?.Location));
    }

    public void SaveSummary(ExitSummary summary)
    {
        if (!ExitSummary.TryNormalizePublicAddress(summary.Address, out var address) ||
            !IsSafeLocation(summary.Location)) return;
        var current = Load();
        Write(new Payload(CurrentVersion, current.PathFingerprint, address, summary.Location));
    }

    public void ClearSummary()
    {
        var current = Load();
        Write(new Payload(CurrentVersion, current.PathFingerprint, null, null));
    }

    private void Write(Payload payload)
    {
        var directory = Path.GetDirectoryName(_path)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
            if (bytes.Length > MaximumBytes) return;
            using (var stream = new FileStream(
                       temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       bufferSize: 4096, options: FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(_path)) File.Replace(temporaryPath, _path, null);
            else File.Move(temporaryPath, _path);
        }
        catch
        {
            // A display cache must never make the application unusable.
        }
        finally
        {
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
            catch { }
        }
    }

    private static bool IsFingerprint(string? value) =>
        value is { Length: 64 } && value.All(character =>
            character is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F');

    private static bool IsSafeLocation(string? value) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= MaximumLocationLength &&
        value.All(character => !char.IsControl(character) && character is not
            '\u061c' and not '\u200e' and not '\u200f' and not
            '\u202a' and not '\u202b' and not '\u202c' and not '\u202d' and not '\u202e' and not
            '\u2066' and not '\u2067' and not '\u2068' and not '\u2069');
}
