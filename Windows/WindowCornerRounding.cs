using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace ProxyGauge;

/// <summary>
/// Clips a borderless WindowChrome window to a rounded-rectangle region so its
/// corners match native Windows 11 / macOS rounding. AllowsTransparency stays off
/// because it breaks caption drag and other native window behaviors.
/// </summary>
public static class WindowCornerRounding
{
    // Windows 11 owns both the rounded outline and its border. Cutting a square
    // WPF border with SetWindowRgn removes the border only at the four corners.
    public static void ApplyMainWindow(Window window)
    {
        window.SourceInitialized += (_, _) => UpdateMainWindowFrame(window);
        window.SizeChanged += (_, _) => UpdateMainWindowFrame(window);
        window.Activated += (_, _) => UpdateMainWindowFrame(window);
        window.StateChanged += (_, _) => UpdateMainWindowFrame(window);
    }

    internal static int UpdateMainWindowFrame(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return unchecked((int)0x80070006);
        // Do not mix a custom region with DWM's corner policy.
        SetWindowRgn(hwnd, IntPtr.Zero, true);
        uint corner = window.WindowState == WindowState.Maximized ? 1u : 2u;
        uint noBorder = 0xFFFFFFFE; // DWMWA_COLOR_NONE: no disconnected dark outline.
        var cornerResult = DwmSetWindowAttribute(hwnd, 33, ref corner, sizeof(uint));
        var borderResult = DwmSetWindowAttribute(hwnd, 34, ref noBorder, sizeof(uint));
        return cornerResult != 0 ? cornerResult : borderResult;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref uint value, int size);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);

    [DllImport("user32.dll")]
    private static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);

    public static void Apply(Window window, double radiusDip)
    {
        window.SourceInitialized += (_, _) => Update(window, radiusDip);
        window.SizeChanged += (_, _) => Update(window, radiusDip);
        window.StateChanged += (_, _) => Update(window, radiusDip);
    }

    private static void Update(Window window, double radiusDip)
    {
        if (PresentationSource.FromVisual(window) is not HwndSource source)
        {
            return;
        }

        var hwnd = source.Handle;
        if (window.WindowState == WindowState.Maximized)
        {
            SetWindowRgn(hwnd, IntPtr.Zero, true);
            return;
        }

        var transform = source.CompositionTarget.TransformToDevice;
        var width = (int)Math.Round(window.ActualWidth * transform.M11);
        var height = (int)Math.Round(window.ActualHeight * transform.M11);
        if (width <= 0 || height <= 0)
        {
            return;
        }

        var radius = (int)Math.Round(radiusDip * 2 * transform.M11);
        var region = CreateRoundRectRgn(0, 0, width + 1, height + 1, radius, radius);
        if (SetWindowRgn(hwnd, region, true) == 0)
        {
            DeleteObject(region); // Ownership transfers to Windows only on success.
        }
    }
}
