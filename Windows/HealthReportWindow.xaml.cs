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
    public string Headline => Report.Passed ? "代理链路工作正常" : "发现需要处理的项目";
    public string Subtitle => Report.Passed
        ? "所有检查均通过，可以正常使用代理。"
        : "失败项目保留了具体原因，建议从上到下处理。";
    public string CheckedAtText => $"检查时间 {Report.CheckedAt:yyyy-MM-dd HH:mm:ss}";
    public string PassedText => $"{Report.PassedCount} 通过";
    public string FailedText => $"{Report.FailedCount} 失败";
    public string StatusMark => Report.Passed ? "✓" : "!";
    public Brush StatusBrush => Report.Passed ? Palette.Success : Palette.Warning;
    public Brush StatusBackground => Report.Passed
        ? Palette.BackgroundForLevel(HealthLevel.Ok)
        : Palette.BackgroundForLevel(HealthLevel.Warning);

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
