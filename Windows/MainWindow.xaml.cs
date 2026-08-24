using System.Windows;
using System.Windows.Input;
using ProxyGauge.Services;
using ProxyGauge.ViewModels;

namespace ProxyGauge;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private readonly RulePackService _rulePackService;
    private readonly ConfigService _configService;
    private readonly ConnectionDiscoveryService _discoveryService;
    private readonly PrivateBrowserService _browserService;
    private readonly bool _needsConnectionSetup;

    public MainWindow()
    {
        InitializeComponent();

        _configService = new ConfigService();
        _needsConnectionSetup = !_configService.HasSavedConfig;
        var probeService = new ProxyProbeService();
        var controllerService = new MihomoControllerService();
        _discoveryService = new ConnectionDiscoveryService(probeService, controllerService);
        var planInspectionService = new MihomoPlanInspectionService(controllerService);
        var healthCheckService = new HealthCheckService(probeService, planInspectionService);
        _browserService = new PrivateBrowserService();
        _rulePackService = new RulePackService();
        _viewModel = new MainViewModel(_configService, probeService, healthCheckService);
        DataContext = _viewModel;

        Loaded += MainWindow_Loaded;
        Closed += (_, _) => _browserService.Dispose();
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
                _viewModel.SaveConfig(setup.Config);
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

        _viewModel.SaveConfig(dialog.Config);
        await _viewModel.RefreshAsync();
    }

    private void RulesButton_Click(object sender, RoutedEventArgs e) =>
        new RulePackWindow(_rulePackService) { Owner = this }.ShowDialog();

    private void PlanButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new DetectionPlanWindow(_viewModel.GetEditableConfig()) { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            _viewModel.SaveConfig(dialog.Config);
        }
    }

    private void AdvancedButton_Click(object sender, RoutedEventArgs e) =>
        new AdvancedDetectionWindow(
            _viewModel.GetEditableConfig(),
            _browserService) { Owner = this }.ShowDialog();

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>
        WindowState = WindowState.Minimized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
