using System.Net;
using System.Windows;
using System.Windows.Input;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class SettingsWindow : Window
{
    private readonly ConnectionDiscoveryService _discoveryService;
    private readonly bool _runDiscoveryOnLoad;
    private bool _isDiscovering;

    public SettingsWindow(
        AppConfig config,
        ConnectionDiscoveryService discoveryService,
        bool runDiscoveryOnLoad = false)
    {
        InitializeComponent();
        WindowCornerRounding.Apply(this, 10);
        _discoveryService = discoveryService;
        _runDiscoveryOnLoad = runDiscoveryOnLoad;
        Config = config.Clone();
        HostTextBox.Text = Config.MixedHost;
        PortTextBox.Text = Config.MixedPort.ToString();
        ExpectedIpTextBox.Text = Config.ExpectedIp;
        TimeoutTextBox.Text = Config.TimeoutSeconds.ToString();
        if (runDiscoveryOnLoad)
        {
            HeaderText.Text = "确认本地连接";
            IntroText.Text = "ProxyGauge 只识别本机回环入口和流量模式，请确认后继续。";
        }
    }

    public AppConfig Config { get; private set; }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        if (_runDiscoveryOnLoad)
        {
            await DiscoverAsync();
        }
    }

    private async void DiscoverButton_Click(object sender, RoutedEventArgs e) =>
        await DiscoverAsync();

    private async Task DiscoverAsync()
    {
        if (_isDiscovering) return;
        _isDiscovering = true;
        DiscoverButton.IsEnabled = false;
        DiscoverButton.Content = "正在检测…";
        DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("MutedTextBrush");
        DiscoveryStatusText.Text = "正在检查 Mihomo 本地控制接口、系统代理和常用回环端口。";
        try
        {
            var result = await _discoveryService.DiscoverAsync(Config);
            if (result.Found)
            {
                HostTextBox.Text = result.Host;
                PortTextBox.Text = result.Port.ToString();
                DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("SuccessBrush");
                DiscoveryStatusText.Text =
                    $"已发现 {result.ClientName} · {result.Endpoint} · {result.TrafficMode}\n来源：{result.Source}";
            }
            else
            {
                DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("WarningBrush");
                DiscoveryStatusText.Text =
                    "没有找到正在监听的 mixed 入口。请先启动代理客户端，或手动填写本机端口。";
            }
        }
        catch
        {
            DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("WarningBrush");
            DiscoveryStatusText.Text = "自动检测暂时不可用；仍可手动填写本机回环端口。";
        }
        finally
        {
            DiscoverButton.Content = "重新检测";
            DiscoverButton.IsEnabled = true;
            _isDiscovering = false;
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        var host = HostTextBox.Text.Trim();
        var expectedIp = ExpectedIpTextBox.Text.Trim();

        if (!LocalEndpointPolicy.IsLoopbackHost(host))
        {
            ValidationText.Text = "主机地址只能是 127.0.0.1、localhost 或其他本机回环地址。";
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

        Config.MixedHost = host;
        Config.MixedPort = port;
        Config.ExpectedIp = expectedIp;
        Config.TimeoutSeconds = timeout;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
