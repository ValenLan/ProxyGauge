using System.Windows;
using System.Windows.Media;

namespace ProxyGauge;

public enum BubbleDialogKind
{
    Info,
    Warning,
    Error,
    Browser
}

public partial class BubbleDialogWindow : Window
{
    private BubbleDialogWindow(
        string title,
        string detail,
        string primaryTitle,
        string? cancelTitle,
        BubbleDialogKind kind)
    {
        InitializeComponent();
        TitleText.Text = title;
        DetailText.Text = detail;
        ConfirmButton.Content = primaryTitle;
        CancelButton.Content = cancelTitle ?? string.Empty;
        CancelButton.Visibility = cancelTitle is null ? Visibility.Collapsed : Visibility.Visible;

        var (stroke, background, geometry) = kind switch
        {
            BubbleDialogKind.Warning => (
                (Brush)FindResource("WarningBrush"),
                (Brush)FindResource("WarningBackgroundBrush"),
                "M9,2 L16,15 H2 Z M9,6 V10 M9,13 L9.01,13"),
            BubbleDialogKind.Error => (
                (Brush)FindResource("ErrorBrush"),
                (Brush)FindResource("ErrorBackgroundBrush"),
                "M3,3 L15,15 M15,3 L3,15"),
            BubbleDialogKind.Browser => (
                (Brush)FindResource("AccentBrush"),
                (Brush)FindResource("AccentSurfaceBrush"),
                "M8,3 H15 V10 M15,3 L7,11 M13,10 V14 C13,15.1 12.1,16 11,16 H4 C2.9,16 2,15.1 2,14 V7 C2,5.9 2.9,5 4,5 H8"),
            _ => (
                (Brush)FindResource("AccentBrush"),
                (Brush)FindResource("AccentSurfaceBrush"),
                "M9,5 L9,5.1 M9,8 V14 M9,2 A7,7 0 1 0 9,16 A7,7 0 1 0 9,2")
        };
        DialogIcon.Stroke = stroke;
        DialogIcon.Data = Geometry.Parse(geometry);
        IconBubble.Background = background;
        if (kind is BubbleDialogKind.Warning or BubbleDialogKind.Error)
        {
            ConfirmButton.Background = stroke;
            ConfirmButton.BorderBrush = stroke;
        }
    }

    public static bool Show(
        Window? owner,
        string title,
        string detail,
        string primaryTitle = "知道了",
        string? cancelTitle = null,
        BubbleDialogKind kind = BubbleDialogKind.Info)
    {
        var dialog = new BubbleDialogWindow(title, detail, primaryTitle, cancelTitle, kind);
        if (owner is not null)
        {
            dialog.Owner = owner;
        }
        else
        {
            dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        return dialog.ShowDialog() == true;
    }

    private void ConfirmButton_Click(object sender, RoutedEventArgs e) => DialogResult = true;

    private void CancelButton_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
