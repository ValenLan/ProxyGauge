using System.Windows;
using System.Windows.Input;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class SettingsWindow : Window
{
    private readonly ConnectionDiscoveryService _discoveryService;
    private readonly UpdateService _updateService;
    private readonly bool _runDiscoveryOnLoad;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private bool _isDiscovering;
    private bool _isClosed;

    public SettingsWindow(
        AppConfig config,
        ConnectionDiscoveryService discoveryService,
        UpdateService updateService,
        bool runDiscoveryOnLoad = false)
    {
        InitializeComponent();
        WindowCornerRounding.Apply(this, 20);
        _discoveryService = discoveryService;
        _updateService = updateService;
        _runDiscoveryOnLoad = runDiscoveryOnLoad;
        Config = config.Clone();
        HostTextBox.Text = Config.MixedHost;
        PortTextBox.Text = Config.MixedPort.ToString();
        ExpectedIpTextBox.Text = Config.ExpectedIp;
        TimeoutTextBox.Text = Config.TimeoutSeconds.ToString();
        VersionText.Text = $"当前版本 v{UpdateService.CurrentVersion}";
        if (runDiscoveryOnLoad)
        {
            HeaderText.Text = "确认本地连接";
            IntroText.Text = "ProxyGauge 只识别本机回环入口和流量模式，请确认后继续。";
        }
        Closed += SettingsWindow_Closed;
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

    private async void CheckUpdateButton_Click(object sender, RoutedEventArgs e)
    {
        CheckUpdateButton.IsEnabled = false;
        CheckUpdateButton.Content = "正在检查…";
        try
        {
            var release = await _updateService.CheckAsync(_lifetimeCancellation.Token);
            if (_isClosed) return;
            if (release is null)
            {
                BubbleDialogWindow.Show(
                    this,
                    "软件更新",
                    $"当前 v{UpdateService.CurrentVersion} 已是最新版。");
                return;
            }

            var answer = BubbleDialogWindow.Show(
                this,
                "发现新版本",
                $"发现 ProxyGauge v{release.Version}。\n\n下载安装包并完成校验后开始更新吗？",
                "下载并更新",
                "稍后");
            if (!answer)
            {
                return;
            }

            CheckUpdateButton.Content = "正在下载…";
            var downloaded = await _updateService.DownloadAsync(
                release,
                _lifetimeCancellation.Token);
            if (_isClosed) return;
            UpdateService.LaunchInstaller(downloaded);
            Application.Current.Shutdown();
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            // Closing this dialog cancels update I/O and must not launch an installer later.
        }
        catch (Exception exception)
        {
            if (_isClosed) return;
            BubbleDialogWindow.Show(
                this,
                "软件更新",
                $"暂时无法完成更新检查。\n\n{exception.Message}",
                kind: BubbleDialogKind.Warning);
        }
        finally
        {
            if (!_isClosed)
            {
                CheckUpdateButton.Content = "检查更新";
                CheckUpdateButton.IsEnabled = true;
            }
        }
    }

    private async Task DiscoverAsync()
    {
        if (_isDiscovering || _isClosed) return;
        _isDiscovering = true;
        DiscoverButton.IsEnabled = false;
        DiscoverButton.Content = "正在检测…";
        DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("MutedTextBrush");
        DiscoveryStatusText.Text = "正在检查 Mihomo 本地控制接口、系统代理和常用回环端口。";
        try
        {
            var result = await _discoveryService.DiscoverAsync(
                Config,
                _lifetimeCancellation.Token);
            if (_isClosed) return;
            if (result.Found)
            {
                HostTextBox.Text = result.Host;
                PortTextBox.Text = result.Port.ToString();
                var routeWarning = result.RouteWarning;
                DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource(
                    routeWarning is null ? "SuccessBrush" : "WarningBrush");
                DiscoveryStatusText.Text = routeWarning is null
                    ? $"已发现 {result.ClientName} · {result.Endpoint} · {result.TrafficMode}\n来源：{result.Source}"
                    : $"已发现 {result.ClientName} · {result.Endpoint} · {result.TrafficMode}\n来源：{result.Source}\n警告：{routeWarning}";
            }
            else
            {
                DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("WarningBrush");
                DiscoveryStatusText.Text = result.RouteWarning is { } routeWarning
                    ? $"{routeWarning} 没有找到 Mihomo mixed 入口；系统实际出口仍会按当前网络路径显示。"
                    : result.TunDetected
                        ? "已确认 Mihomo 代表性 TUN 路由，但没有找到 mixed 入口。TUN-only 模式可以不开放该端口。"
                        : result.OtherTunnelDetected
                            ? "已检测到其他 VPN/TUN 系统路径；系统实际出口会按当前网络路径显示。"
                        : "没有找到正在监听的 mixed 入口。请先启动代理客户端，或手动填写本机端口。";
            }
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            // The dialog was closed while discovery was in progress.
        }
        catch
        {
            if (_isClosed) return;
            DiscoveryStatusText.Foreground = (System.Windows.Media.Brush)FindResource("WarningBrush");
            DiscoveryStatusText.Text = "自动检测暂时不可用；仍可手动填写本机回环端口。";
        }
        finally
        {
            if (!_isClosed)
            {
                DiscoverButton.Content = "重新检测";
                DiscoverButton.IsEnabled = true;
            }
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

        var normalizedExpectedIp = string.Empty;
        if (expectedIp.Length > 0 &&
            !ExitSummary.TryNormalizePublicAddress(expectedIp, out normalizedExpectedIp))
        {
            ValidationText.Text = "期望出口必须是规范的公网 IPv4 或 IPv6，也可以留空。";
            return;
        }

        Config.MixedHost = host;
        Config.MixedPort = port;
        Config.ExpectedIp = expectedIp.Length == 0 ? string.Empty : normalizedExpectedIp;
        Config.TimeoutSeconds = timeout;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    private void SettingsWindow_Closed(object? sender, EventArgs e)
    {
        _isClosed = true;
        Closed -= SettingsWindow_Closed;
        _lifetimeCancellation.Cancel();
    }
}
