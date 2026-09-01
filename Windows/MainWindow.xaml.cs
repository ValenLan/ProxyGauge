using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ProxyGauge.Models;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

namespace ProxyGauge;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly ConfigService _configService;
    private readonly ConnectionDiscoveryService _discoveryService;
    private readonly ThemeService _themeService;
    private readonly UpdateService _updateService;
    private readonly bool _needsConnectionSetup;

    private static readonly string[] ManualReviewDirectUrls =
    [
        "https://ippure.com/",
        "https://ipcheck.ing/?hl=zh",
        "https://browserleaks.com/ip",
        "https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test"
    ];

    private static readonly string[] PrivacyReviewUrls =
    [
        "https://browserleaks.com/ip",
        "https://browserleaks.com/webrtc",
        "https://www.dnsleaktest.com/",
        "https://test-ipv6.com/"
    ];

    public MainWindow(ThemeService themeService)
    {
        InitializeComponent();
        WindowCornerRounding.Apply(this, 10);

        _themeService = themeService;
        _updateService = new UpdateService();
        _configService = new ConfigService();
        _needsConnectionSetup = !_configService.HasValidConfig;
        var probeService = new ProxyProbeService();
        var controllerService = new MihomoControllerService();
        _discoveryService = new ConnectionDiscoveryService(probeService, controllerService);
        var planInspectionService = new MihomoPlanInspectionService(controllerService);
        var healthCheckService = new HealthCheckService(probeService, planInspectionService);
        var guardClient = new GuardClient();
        _viewModel = new MainViewModel(_configService, probeService, healthCheckService, guardClient);
        DataContext = _viewModel;

        Loaded += MainWindow_Loaded;
        Closed += (_, _) => _updateService.Dispose();
        StateChanged += (_, _) => UpdateMaxRestoreIcon();
        // Guard is intentionally not contacted on close. Closing the UI must never disable protection.
    }

    private void MaximizeButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;

    private void UpdateMaxRestoreIcon()
    {
        MaximizeIcon.Data = Geometry.Parse(WindowState == WindowState.Maximized
            ? "M3.6,1.4 L8.6,1.4 L8.6,6.4 L6.6,6.4 M1.4,3.6 L6.4,3.6 L6.4,8.6 L1.4,8.6 Z"
            : "M1.8,1.8 L8.2,1.8 L8.2,8.2 L1.8,8.2 Z");
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        if (_needsConnectionSetup)
        {
            var setup = new SettingsWindow(
                _viewModel.GetEditableConfig(),
                _discoveryService,
                _updateService,
                runDiscoveryOnLoad: true) { Owner = this };
            if (setup.ShowDialog() == true)
            {
                TrySaveConfig(setup.Config);
            }
        }

        await _viewModel.RefreshAsync();
        UpdateThemeIcon();
        await CheckForUpdatesAsync(silent: true);
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) =>
        await _viewModel.RefreshAsync();

    private async void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(
            _viewModel.GetEditableConfig(),
            _discoveryService,
            _updateService) { Owner = this };
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
                BubbleDialogWindow.Show(
                    this,
                    "ProxyGauge 系统保护",
                    $"设置已保存，但断网保护仍保留原规则并继续阻止直连。\n\n{exception.Message}",
                    kind: BubbleDialogKind.Warning);
            }
            catch (Exception exception)
            {
                BubbleDialogWindow.Show(
                    this,
                    "ProxyGauge 系统保护",
                    $"设置已保存，但断网保护无法切换到新的检测入口。原有规则仍保留并继续阻止直连。\n\n{exception.Message}",
                    kind: BubbleDialogKind.Warning);
            }
            await _viewModel.RefreshAsync();
        }
    }

    private void ThemeButton_Click(object sender, RoutedEventArgs e)
    {
        _themeService.ToggleTheme();
        UpdateThemeIcon();
    }

    private void UpdateThemeIcon()
    {
        var isDark = _themeService.CurrentTheme == AppThemeKind.Dark;
        ThemeSunIcon.Visibility = isDark ? Visibility.Collapsed : Visibility.Visible;
        ThemeMoonIcon.Visibility = isDark ? Visibility.Visible : Visibility.Collapsed;
    }

    private void CopyExitButton_Click(object sender, RoutedEventArgs e)
    {
        var address = _viewModel.ExitAddress;
        if (string.IsNullOrWhiteSpace(address) || address.Contains("无法", StringComparison.Ordinal) || address.Contains("读取", StringComparison.Ordinal))
        {
            return;
        }
        if (!TrySetClipboardText(address.Trim()))
        {
            BubbleDialogWindow.Show(
                this,
                "复制失败",
                "系统剪贴板正被其他程序占用，请稍后再试。",
                kind: BubbleDialogKind.Error);
            return;
        }
        ShowCopyFeedback();
    }

    private static bool TrySetClipboardText(string text)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(text, true);
                return true;
            }
            catch (ExternalException) when (attempt < 2)
            {
                Thread.Sleep(25);
            }
            catch (ExternalException)
            {
                return false;
            }
        }
        return false;
    }

    private async void ShowCopyFeedback()
    {
        CopyExitFront.Visibility = Visibility.Collapsed;
        CopyExitBack.Visibility = Visibility.Collapsed;
        CopyExitCheckmark.Visibility = Visibility.Visible;
        CopyExitButton.ToolTip = "出口 IP 已复制";
        await Task.Delay(1500);
        CopyExitFront.Visibility = Visibility.Visible;
        CopyExitBack.Visibility = Visibility.Visible;
        CopyExitCheckmark.Visibility = Visibility.Collapsed;
        CopyExitButton.ToolTip = "复制出口 IP";
    }

    private void IpPurityButton_Click(object sender, RoutedEventArgs e) =>
        ConfirmBrowserOpen(
            "IP 纯净度检测",
            "将使用默认浏览器打开 4 个第三方检测页面。ProxyGauge 不会读取或保存页面内容。",
            ManualReviewDirectUrls);

    private void PrivacyButton_Click(object sender, RoutedEventArgs e) =>
        ConfirmBrowserOpen(
            "隐私泄露检测",
            "将使用默认浏览器打开 DNS、WebRTC、IPv6 等 4 个检测页面。",
            PrivacyReviewUrls);

    private void SpeedButton_Click(object sender, RoutedEventArgs e) =>
        ConfirmBrowserOpen(
            "浏览器测速",
            "将使用默认浏览器打开 Cloudflare 测速页面，测量浏览器真实路径。",
            ["https://speed.cloudflare.com/"]);

    private void ConfirmBrowserOpen(string title, string detail, IEnumerable<string> urls)
    {
        if (BubbleDialogWindow.Show(
                this,
                $"打开{title}？",
                detail,
                "继续打开",
                "取消",
                BubbleDialogKind.Browser))
        {
            OpenUrls(urls);
        }
    }

    private static void OpenUrls(IEnumerable<string> urls)
    {
        foreach (var url in urls)
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            }
            catch
            {
                // A browser launch failure must not change proxy or guard state.
            }
        }
    }

    private async Task CheckForUpdatesAsync(bool silent)
    {
        try
        {
            var release = await _updateService.CheckAsync();
            if (release is null)
            {
                if (!silent)
                {
                    BubbleDialogWindow.Show(
                        this,
                        "软件更新",
                        $"当前 v{UpdateService.CurrentVersion} 已是最新版。");
                }
                return;
            }

            var answer = BubbleDialogWindow.Show(
                this,
                "发现新版本",
                $"发现 ProxyGauge v{release.Version}。\n\n下载后会校验 SHA-256，并由 Windows Installer 完成更新。",
                "下载并更新",
                "稍后");
            if (!answer)
            {
                return;
            }

            Mouse.OverrideCursor = Cursors.Wait;
            try
            {
                var downloaded = await _updateService.DownloadAsync(release);
                UpdateService.LaunchInstaller(downloaded);
                Application.Current.Shutdown();
            }
            finally
            {
                Mouse.OverrideCursor = null;
            }
        }
        catch (Exception exception)
        {
            if (!silent)
            {
                BubbleDialogWindow.Show(
                    this,
                    "软件更新",
                    $"暂时无法完成更新检查。\n\n{exception.Message}",
                    kind: BubbleDialogKind.Warning);
            }
        }
    }

    private async void GuardButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.GuardEnabled)
        {
            var answer = BubbleDialogWindow.Show(
                this,
                "关闭断网保护？",
                "关闭后，网络路径发生变化时，Windows 可能通过真实 IP 直接联网。",
                "确认关闭",
                "取消",
                BubbleDialogKind.Warning);
            if (!answer)
            {
                if (sender is CheckBox toggle)
                {
                    toggle.IsChecked = true;
                }
                return;
            }
        }

        try
        {
            await _viewModel.ToggleGuardAsync();
        }
        catch (GuardCommandException exception)
        {
            BubbleDialogWindow.Show(
                this,
                "ProxyGauge 系统保护",
                exception.Message,
                kind: BubbleDialogKind.Warning);
            await _viewModel.RefreshAsync();
        }
        catch (Exception exception)
        {
            BubbleDialogWindow.Show(
                this,
                "ProxyGauge 系统保护",
                $"系统保护操作没有完成。\n\n{exception.Message}",
                kind: BubbleDialogKind.Warning);
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
            BubbleDialogWindow.Show(
                this,
                "ProxyGauge",
                $"设置无法保存，原配置未被替换。\n\n{exception.Message}",
                kind: BubbleDialogKind.Warning);
            return false;
        }
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
