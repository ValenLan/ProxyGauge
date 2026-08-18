using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CloudRoute.Models;
using CloudRoute.ViewModels;

namespace CloudRoute;

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
            ? "网络可用，仍有需要留意的项目"
            : "网络检查通过";
    public string Subtitle => Report.FailedCount > 0
        ? "失败项目保留了具体原因，建议从上到下处理。"
        : Report.WarningCount > 0
            ? "网络可用；请按提示复查实际链路或配置。"
            : "本地代理、出口与自动风险检查通过。";
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

    private void OpenLinkButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string url } ||
            !Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)) return;

        try
        {
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
        }
        catch
        {
            // The URL remains visible in copied results if Windows has no browser association.
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
