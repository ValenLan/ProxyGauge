using System.Text;

namespace PuffRoute.Models;

public sealed record HealthCheckItem(string Label, string Detail, bool Passed)
{
    public string Mark => Passed ? "✓" : "×";
    public string LevelKey => Passed ? "Ok" : "Error";
}

public sealed record HealthCheckSection(string Title, IReadOnlyList<HealthCheckItem> Items)
{
    public bool Passed => Items.All(item => item.Passed);
}

public sealed class HealthReport
{
    public required DateTime CheckedAt { get; init; }
    public required IReadOnlyList<HealthCheckSection> Sections { get; init; }

    public int PassedCount => Sections.SelectMany(section => section.Items).Count(item => item.Passed);
    public int FailedCount => Sections.SelectMany(section => section.Items).Count(item => !item.Passed);
    public bool Passed => FailedCount == 0;

    public string ToPlainText()
    {
        var text = new StringBuilder();
        text.AppendLine($"PuffRoute Windows 健康检查 · {CheckedAt:yyyy-MM-dd HH:mm:ss}");
        text.AppendLine($"结果：{PassedCount} 通过 / {FailedCount} 失败");
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
