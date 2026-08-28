using System.Net;
using System.Windows;
using System.Windows.Input;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class DetectionPlanWindow : Window
{
    public DetectionPlanWindow(AppConfig config)
    {
        InitializeComponent();
        Config = config.Clone();
        EnableCheckBox.IsChecked = Config.SecondaryEnabled;
        LabelTextBox.Text = Config.SecondaryLabel;
        SecondaryGroupTextBox.Text = Config.SecondaryGroup;
        DefaultGroupTextBox.Text = Config.DefaultGroup;
        SecondaryHostTextBox.Text = Config.SecondaryMixedHost;
        SecondaryPortTextBox.Text = Config.SecondaryMixedPort.ToString();
        DomainsTextBox.Text = Config.SecondaryDomains;
        ExpectedSecondaryIpTextBox.Text = Config.ExpectedSecondaryIp;
        UpdateEnabledState();
    }

    public AppConfig Config { get; private set; }

    private void EnableCheckBox_Changed(object sender, RoutedEventArgs e) => UpdateEnabledState();

    private void UpdateEnabledState()
    {
        if (SecondaryFields is not null)
        {
            SecondaryFields.IsEnabled = EnableCheckBox.IsChecked == true;
            SecondaryFields.Opacity = EnableCheckBox.IsChecked == true ? 1 : 0.52;
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        var enabled = EnableCheckBox.IsChecked == true;
        var label = LabelTextBox.Text.Trim();
        var secondaryGroup = SecondaryGroupTextBox.Text.Trim();
        var defaultGroup = DefaultGroupTextBox.Text.Trim();
        var host = SecondaryHostTextBox.Text.Trim();
        var domains = DomainsTextBox.Text
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var expectedIp = ExpectedSecondaryIpTextBox.Text.Trim();

        if (enabled && (string.IsNullOrWhiteSpace(label) || label.Any(char.IsControl)))
        {
            ValidationText.Text = "请输入简短的方案名称。";
            return;
        }
        if (enabled && (string.IsNullOrWhiteSpace(secondaryGroup) || string.IsNullOrWhiteSpace(defaultGroup)))
        {
            ValidationText.Text = "额外策略组和默认策略组不能为空。";
            return;
        }
        if (enabled && !LocalEndpointPolicy.IsLoopbackHost(host))
        {
            ValidationText.Text = "额外入口只能使用本机回环地址。";
            return;
        }
        var port = Config.SecondaryMixedPort;
        if (enabled &&
            (!int.TryParse(SecondaryPortTextBox.Text.Trim(), out port) || port is < 1 or > 65535))
        {
            ValidationText.Text = "额外入口端口必须是 1–65535 之间的数字。";
            return;
        }
        if (enabled && (domains.Length == 0 || domains.Any(domain =>
                Uri.CheckHostName(domain) == UriHostNameType.Unknown)))
        {
            ValidationText.Text = "请填写有效的目标域名，并使用英文逗号分隔。";
            return;
        }
        if (enabled && expectedIp.Length > 0 && !IPAddress.TryParse(expectedIp, out _))
        {
            ValidationText.Text = "额外出口期望 IP 的格式不正确，也可以留空。";
            return;
        }

        Config.SecondaryEnabled = enabled;
        if (enabled)
        {
            Config.SecondaryLabel = label;
            Config.SecondaryGroup = secondaryGroup;
            Config.DefaultGroup = defaultGroup;
            Config.SecondaryMixedHost = host;
            Config.SecondaryMixedPort = port;
            Config.SecondaryDomains = string.Join(',', domains);
            Config.ExpectedSecondaryIp = expectedIp;
        }
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
