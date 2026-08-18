using System.Text;

namespace CloudRoute.Models;

public sealed record HealthCheckItem(string Label, string Detail, HealthLevel Level)
{
    public HealthCheckItem(string label, string detail, bool passed)
        : this(label, detail, passed ? HealthLevel.Ok : HealthLevel.Error)
    {
    }

    public string Mark => Level switch
    {
        HealthLevel.Ok => "✓",
        HealthLevel.Warning => "!",
        HealthLevel.Error => "×",
        _ => "i"
    };

    public bool Passed => Level == HealthLevel.Ok;
    public string LevelKey => Level.ToString();
    public bool IsLink => Uri.TryCreate(Detail, UriKind.Absolute, out var uri) &&
        (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp);
}

public sealed record HealthCheckSection(string Title, IReadOnlyList<HealthCheckItem> Items)
{
    public bool Passed => Items.All(item => item.Level != HealthLevel.Error);
}

public sealed class HealthReport
{
    public required DateTime CheckedAt { get; init; }
    public required IReadOnlyList<HealthCheckSection> Sections { get; init; }

    public int PassedCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Ok);
    public int WarningCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Warning);
    public int FailedCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Error);
    public bool Passed => FailedCount == 0;

    public string ToPlainText()
    {
        var text = new StringBuilder();
        text.AppendLine($"CloudRoute Windows 健康检查 · {CheckedAt:yyyy-MM-dd HH:mm:ss}");
        text.AppendLine($"结果：{PassedCount} 通过 / {WarningCount} 提示 / {FailedCount} 失败");
        text.AppendLine();

        foreach (var section in Sections)
        {
            text.AppendLine($"[{section.Title}]");
            foreach (var item in section.Items)
            {
                text.AppendLine($"{item.Mark} {item.Label} — {item.Detail}");
            }
            text.AppendLine();
        }

        return text.ToString().TrimEnd();
    }
}
