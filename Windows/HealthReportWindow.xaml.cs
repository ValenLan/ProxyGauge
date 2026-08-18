using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using PuffRoute.Models;
using PuffRoute.ViewModels;

namespace PuffRoute;

public partial class HealthReportWindow : Window
{
    public HealthReportWindow(HealthReport report)
    {
        InitializeComponent();
        Report = report;
        DataContext = this;
    }

    public HealthReport Report { get; }
    public string Headline => Report.FailedCount > 0
        ? "发现需要处理的项目"
        : Report.WarningCount > 0
            ? "代理可用，风险画像需留意"
            : "代理链路工作正常";
    public string Subtitle => Report.FailedCount > 0
        ? "失败项目保留了具体原因，建议从上到下处理。"
        : Report.WarningCount > 0
            ? "风险指标来自第三方情报，仅供参考，不代表目标网站一定封禁。"
            : "所有链路检查均通过，可以正常使用代理。";
    public string CheckedAtText => $"检查时间 {Report.CheckedAt:yyyy-MM-dd HH:mm:ss}";
    public string PassedText => $"{Report.PassedCount} 通过";
    public string WarningText => $"{Report.WarningCount} 提示";
    public string FailedText => $"{Report.FailedCount} 失败";
    public string StatusMark => Report.FailedCount == 0 && Report.WarningCount == 0 ? "✓" : "!";
    public Brush StatusBrush => Report.FailedCount > 0
        ? Palette.Error
        : Report.WarningCount > 0 ? Palette.Warning : Palette.Success;
    public Brush StatusBackground => Report.FailedCount > 0
        ? Palette.BackgroundForLevel(HealthLevel.Error)
        : Report.WarningCount > 0
            ? Palette.BackgroundForLevel(HealthLevel.Warning)
            : Palette.BackgroundForLevel(HealthLevel.Ok);

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(Report.ToPlainText());
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
