using System.Windows;
using ProxyGauge.Services;

namespace ProxyGauge;

public partial class App : Application
{
    private ThemeService? _themeService;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            MessageBox.Show(
                "ProxyGauge 仅支持 Windows 11，不支持 Windows 10。",
                "ProxyGauge",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        _themeService = new ThemeService();
        _themeService.Start();

        ShutdownMode = ShutdownMode.OnMainWindowClose;
        MainWindow = new MainWindow();
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _themeService?.Dispose();
        base.OnExit(e);
    }
}
