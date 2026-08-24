using System.Windows;
using System.Windows.Input;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class AdvancedDetectionWindow : Window
{
    private readonly AppConfig _config;
    private readonly PrivateBrowserService _browserService;
    private bool _isLaunching;

    public AdvancedDetectionWindow(AppConfig config, PrivateBrowserService browserService)
    {
        InitializeComponent();
        _config = config.Clone();
        _browserService = browserService;
        DefaultEndpointText.Text = $"{_config.MixedHost}:{_config.MixedPort}";
        SecondaryLabelText.Text = _config.SecondaryLabel;
        SecondaryEndpointText.Text = $"{_config.SecondaryMixedHost}:{_config.SecondaryMixedPort}";
        SecondaryCard.Visibility = _config.SecondaryEnabled ? Visibility.Visible : Visibility.Collapsed;
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }

    private async void DefaultButton_Click(object sender, RoutedEventArgs e) =>
        await LaunchAsync("默认出口", _config.MixedHost, _config.MixedPort);

    private async void SecondaryButton_Click(object sender, RoutedEventArgs e) =>
        await LaunchAsync(_config.SecondaryLabel, _config.SecondaryMixedHost, _config.SecondaryMixedPort);

    private async Task LaunchAsync(string routeLabel, string host, int port)
    {
        if (_isLaunching) return;
        _isLaunching = true;
        DefaultButton.IsEnabled = false;
        SecondaryButton.IsEnabled = false;
        StatusText.Foreground = (System.Windows.Media.Brush)FindResource("MutedTextBrush");
        StatusText.Text = $"正在准备 {routeLabel} 隔离窗口…";
        try
        {
            var result = await _browserService.LaunchAsync(
                routeLabel,
                host,
                port,
                _config.TimeoutSeconds);
            StatusText.Foreground = (System.Windows.Media.Brush)FindResource(
                result.Started ? "SuccessBrush" : "ErrorBrush");
            StatusText.Text = result.Started
                ? $"{result.BrowserName} · {result.RouteLabel}\n{result.Message}"
                : result.Message;
        }
        finally
        {
            DefaultButton.IsEnabled = true;
            SecondaryButton.IsEnabled = true;
            _isLaunching = false;
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
