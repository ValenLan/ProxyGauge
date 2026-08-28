using System.Windows;

namespace ProxyGauge;

public partial class App : Application
{
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

        ShutdownMode = ShutdownMode.OnMainWindowClose;
        MainWindow = new MainWindow();
        MainWindow.Show();
    }
}
