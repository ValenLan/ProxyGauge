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

public sealed record HealthCheckSection(
    string Title,
    IReadOnlyList<HealthCheckItem> Items,
    int Weight,
    bool IsCritical = false)
{
    public bool Passed => Items.All(item => item.Level != HealthLevel.Error);
    public bool HasWarning => Items.Any(item => item.Level == HealthLevel.Warning);
    public bool HasFailure => Items.Any(item => item.Level == HealthLevel.Error);
}

public sealed class HealthReport
{
    public required DateTime CheckedAt { get; init; }
    public required IReadOnlyList<HealthCheckSection> Sections { get; init; }

    public int PassedCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Ok);
    public int WarningCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Warning);
    public int FailedCount => Sections.SelectMany(section => section.Items).Count(item => item.Level == HealthLevel.Error);
    public bool Passed => FailedCount == 0;
    public int Score
    {
        get
        {
            var value = (int)Math.Round(Sections.Sum(section => section.HasFailure
                ? 0
                : section.HasWarning ? section.Weight * 0.5 : section.Weight));
            if (Sections.Any(section => section.IsCritical && section.HasFailure))
            {
                value = Math.Min(value, 49);
            }
            else if (FailedCount > 0)
            {
                value = Math.Min(value, 69);
            }
            return Math.Clamp(value, 0, 100);
        }
    }
    public string ScoreLabel => Score >= 90 ? "良好" : Score >= 50 ? "需改进" : "异常";

    public string ToPlainText()
    {
        var text = new StringBuilder();
        text.AppendLine($"CloudRoute Windows 健康检查 · {CheckedAt:yyyy-MM-dd HH:mm:ss}");
        text.AppendLine($"健康分：{Score}/100 · {ScoreLabel}");
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
