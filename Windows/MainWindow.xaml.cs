using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

namespace ProxyGauge;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly RulePackService _rulePackService;
    private readonly ConfigService _configService;
    private readonly ConnectionDiscoveryService _discoveryService;
    private readonly bool _needsConnectionSetup;

    private static readonly string[] ManualReviewDirectUrls =
    [
        "https://ippure.com/",
        "https://ipcheck.ing/?hl=zh",
        "https://browserleaks.com/ip",
        "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test"
    ];

    public MainWindow()
    {
        InitializeComponent();

        _configService = new ConfigService();
        _needsConnectionSetup = !_configService.HasValidConfig;
        var probeService = new ProxyProbeService();
        var controllerService = new MihomoControllerService();
        _discoveryService = new ConnectionDiscoveryService(probeService, controllerService);
        var planInspectionService = new MihomoPlanInspectionService(controllerService);
        var healthCheckService = new HealthCheckService(probeService, planInspectionService);
        var guardClient = new GuardClient();
        _rulePackService = new RulePackService();
        _viewModel = new MainViewModel(_configService, probeService, healthCheckService, guardClient);
        DataContext = _viewModel;

        Loaded += MainWindow_Loaded;
        // Guard is intentionally not contacted on close. Closing the UI must never disable protection.
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        if (_needsConnectionSetup)
        {
            var setup = new SettingsWindow(
                _viewModel.GetEditableConfig(),
                _discoveryService,
                runDiscoveryOnLoad: true) { Owner = this };
            if (setup.ShowDialog() == true)
            {
                TrySaveConfig(setup.Config);
            }
        }

        await _viewModel.RefreshAsync();
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) =>
        await _viewModel.RefreshAsync();

    private async void HealthButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var report = await _viewModel.RunHealthCheckAsync();
            if (report is not null)
            {
                new HealthReportWindow(report) { Owner = this }.ShowDialog();
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                $"链路检测没有完成。\n\n{exception.Message}",
                "ProxyGauge",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(
            _viewModel.GetEditableConfig(),
            _discoveryService) { Owner = this };
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        if (TrySaveConfig(dialog.Config))
        {
            try
            {
                await _viewModel.ReconfigureGuardAsync();
            }
            catch (GuardCommandException exception)
            {
                MessageBox.Show(
                    this,
                    $"设置已保存，但系统保护仍保持原来的代理核心规则并继续阻止直连。\n\n{exception.Message}",
                    "ProxyGauge 系统保护",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    this,
                    $"设置已保存，但系统保护无法切换到新的代理入口。原有规则仍保留并继续阻止直连。\n\n{exception.Message}",
                    "ProxyGauge 系统保护",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
            await _viewModel.RefreshAsync();
        }
    }

    private void RulesButton_Click(object sender, RoutedEventArgs e) =>
        new RulePackWindow(_rulePackService) { Owner = this }.ShowDialog();

    private void PlanButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new DetectionPlanWindow(_viewModel.GetEditableConfig()) { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            TrySaveConfig(dialog.Config);
        }
    }

    private async void AdvancedButton_Click(object sender, RoutedEventArgs e)
    {
        var answer = MessageBox.Show(
            this,
            "确认后会先经当前本地代理入口读取出口 IP，再使用系统默认浏览器打开 6 个复核网站。\n\nScamalytics 与 AbuseIPDB 会直接进入该 IP 的结果页；部分网站可能要求人机验证，各站结果不会计入链路分。\n\n是否继续？",
            "打开浏览器人工复核？",
            MessageBoxButton.YesNo,
            MessageBoxImage.Information,
            MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes)
        {
            return;
        }

        Mouse.OverrideCursor = Cursors.Wait;
        string? exitIp;
        try
        {
            exitIp = await HealthCheckService.ResolveDefaultExitIpAsync(_viewModel.GetEditableConfig());
        }
        catch
        {
            exitIp = null;
        }
        finally
        {
            Mouse.OverrideCursor = null;
        }

        var reviewUrls = ManualReviewDirectUrls.ToList();
        if (exitIp is not null)
        {
            var escapedIp = Uri.EscapeDataString(exitIp);
            reviewUrls.Add($"https://scamalytics.com/ip/{escapedIp}");
            reviewUrls.Add($"https://www.abuseipdb.com/check/{escapedIp}");
        }

        var failedCount = 0;
        foreach (var url in reviewUrls)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true
                });
            }
            catch
            {
                failedCount++;
            }
        }

        if (exitIp is null)
        {
            MessageBox.Show(
                this,
                "无法经当前本地代理入口确认出口 IP，因此没有打开需要 IP 参数的 Scamalytics 和 AbuseIPDB。其余 4 个网站已按正常方式打开；ProxyGauge 没有改动代理配置。",
                "复核网站未完整打开",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
        else if (failedCount > 0)
        {
            MessageBox.Show(
                this,
                "部分网站未能打开，请检查系统默认浏览器设置后重试。ProxyGauge 没有更改代理或浏览器配置。",
                "ProxyGauge",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async void GuardButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.GuardEnabled)
        {
            var answer = MessageBox.Show(
                this,
                "关闭后，Windows 将允许流量绕过代理直接联网，真实 IP 可能暴露。\n\n确定关闭系统保护吗？",
                "关闭系统保护？",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                return;
            }
        }

        try
        {
            await _viewModel.ToggleGuardAsync();
        }
        catch (GuardCommandException exception)
        {
            MessageBox.Show(
                this,
                exception.Message,
                "ProxyGauge 系统保护",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            await _viewModel.RefreshAsync();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                $"系统保护操作没有完成。\n\n{exception.Message}",
                "ProxyGauge 系统保护",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            await _viewModel.RefreshAsync();
        }
    }

    private bool TrySaveConfig(AppConfig config)
    {
        try
        {
            _viewModel.SaveConfig(config);
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                $"设置无法保存，原配置未被替换。\n\n{exception.Message}",
                "ProxyGauge",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return false;
        }
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
