using System.Net;
using System.Windows;
using System.Windows.Input;
using PuffRoute.Models;

namespace PuffRoute;

public partial class SettingsWindow : Window
{
    public SettingsWindow(AppConfig config)
    {
        InitializeComponent();
        Config = config.Clone();
        HostTextBox.Text = Config.MixedHost;
        PortTextBox.Text = Config.MixedPort.ToString();
        ExpectedIpTextBox.Text = Config.ExpectedIp;
        TimeoutTextBox.Text = Config.TimeoutSeconds.ToString();
    }

    public AppConfig Config { get; private set; }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        var host = HostTextBox.Text.Trim();
        var expectedIp = ExpectedIpTextBox.Text.Trim();

        if (string.IsNullOrWhiteSpace(host) || host.Any(char.IsWhiteSpace))
        {
            ValidationText.Text = "请输入有效的本地代理主机地址。";
            return;
        }

        if (!int.TryParse(PortTextBox.Text.Trim(), out var port) || port is < 1 or > 65535)
        {
            ValidationText.Text = "端口必须是 1–65535 之间的数字。";
            return;
        }

        if (!int.TryParse(TimeoutTextBox.Text.Trim(), out var timeout) || timeout is < 3 or > 30)
        {
            ValidationText.Text = "超时时间必须是 3–30 秒。";
            return;
        }

        if (expectedIp.Length > 0 && !IPAddress.TryParse(expectedIp, out _))
        {
            ValidationText.Text = "期望出口 IP 的格式不正确，也可以留空。";
            return;
        }

        Config = new AppConfig
        {
            MixedHost = host,
            MixedPort = port,
            ExpectedIp = expectedIp,
            TimeoutSeconds = timeout
        };
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
