using System.IO;
using System.Windows;
using System.Windows.Controls;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class GuardApplicationWindow : Window
{
    public GuardApplicationWindow(GuardApplicationRequest request)
    {
        InitializeComponent();
        ExplanationText.Text = request.Reason == "PROXY_AMBIGUOUS"
            ? "发现多个运行中的代理核心，请选择要信任的一个。"
            : request.PreviousPath.Length > 0
                ? "之前选定的核心未运行。请启动它后重试，或明确选择另一个应用。"
                : "暂未识别到正在运行的代理核心。请先启动代理后重试；未适配的客户端可手动选择核心程序。";
        ApplicationList.ItemsSource = request.Applications.Select(choice =>
            new ProxyApplicationChoice(Path.GetFileNameWithoutExtension(choice.ExecutablePath), choice.ExecutablePath)).ToArray();
        // No preselected fallback: changing the trusted application requires an explicit choice.
    }

    public string? SelectedPath { get; private set; }

    private void ApplicationList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (EnableButton is not null) EnableButton.IsEnabled = ApplicationList.SelectedItem is ProxyApplicationChoice;
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "选择实际联网的代理核心（不是启动器或辅助服务）",
            Filter = "代理核心程序 (*.exe)|*.exe", CheckFileExists = true, Multiselect = false
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var path = ProxyApplicationSelection.NormalizePath(dialog.FileName);
            var choice = new ProxyApplicationChoice(Path.GetFileNameWithoutExtension(path), path);
            ApplicationList.ItemsSource = new[] { choice };
            ApplicationList.SelectedItem = choice;
            ValidationText.Text = string.Empty;
        }
        catch (InvalidDataException exception) { ValidationText.Text = exception.Message; }
    }

    private void Enable_Click(object sender, RoutedEventArgs e)
    {
        if (ApplicationList.SelectedItem is not ProxyApplicationChoice choice) return;
        SelectedPath = choice.ExecutablePath;
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
