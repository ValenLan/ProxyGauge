using Microsoft.Win32;
using System.Windows;
using System.Windows.Input;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class RulePackWindow : Window
{
    private readonly RulePackService _service;

    public RulePackWindow(RulePackService service)
    {
        InitializeComponent();
        _service = service;
        RuleText = _service.Read();
        DataContext = this;
    }

    public string RuleText { get; }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(RuleText);
        StatusText.Text = "已复制，可粘贴到新的 Merge 配置";
    }

    private void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog
        {
            Title = "导出 ProxyGauge 规则包",
            FileName = "ProxyGauge-Merge.yaml",
            DefaultExt = ".yaml",
            Filter = "YAML 配置 (*.yaml)|*.yaml|所有文件 (*.*)|*.*"
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            _service.Export(dialog.FileName);
            StatusText.Text = $"已导出 {System.IO.Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception exception)
        {
            StatusText.Text = $"导出失败：{exception.Message}";
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
