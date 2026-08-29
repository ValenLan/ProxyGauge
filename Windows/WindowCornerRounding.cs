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
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);

    [DllImport("user32.dll")]
    private static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

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
        SetWindowRgn(hwnd, region, true);
    }
}
