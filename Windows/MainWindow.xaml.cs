using System.Windows;
using System.Windows.Input;
using CloudLinkGuard.Services;
using CloudLinkGuard.ViewModels;

namespace CloudLinkGuard;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly RulePackService _rulePackService;

    public MainWindow()
    {
        InitializeComponent();

        var configService = new ConfigService();
        var probeService = new ProxyProbeService();
        var healthCheckService = new HealthCheckService(probeService);
        _rulePackService = new RulePackService();
        _viewModel = new MainViewModel(configService, probeService, healthCheckService);
        DataContext = _viewModel;

        Loaded += async (_, _) => await _viewModel.RefreshAsync();
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
                "CloudCheck",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(_viewModel.GetEditableConfig()) { Owner = this };
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        _viewModel.SaveConfig(dialog.Config);
        await _viewModel.RefreshAsync();
    }

    private void RulesButton_Click(object sender, RoutedEventArgs e) =>
        new RulePackWindow(_rulePackService) { Owner = this }.ShowDialog();

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
