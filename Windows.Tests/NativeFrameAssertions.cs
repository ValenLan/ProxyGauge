using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

internal static class NativeFrameAssertions
{
    public static void Check(Window window)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        RequireAttribute(hwnd, 33, 2);
        // BORDER_COLOR is a set-only attribute on Windows; Get returns E_INVALIDARG.
        var result = ProxyGauge.WindowCornerRounding.UpdateMainWindowFrame(window);
        if (result != 0)
            throw new InvalidOperationException($"DWM rejected the rounded, borderless frame: {result:X8}.");
        var region = CreateRectRgn(0, 0, 0, 0);
        try
        {
            if (GetWindowRgn(hwnd, region) != 0)
                throw new InvalidOperationException("The main window must not use a region that disables native DWM rounding.");
        }
        finally { DeleteObject(region); }
        if (window.IsVisible)
            throw new InvalidOperationException("Native frame verification must not show or operate the app.");
    }

    private static void RequireAttribute(IntPtr hwnd, int attribute, uint expected)
    {
        var result = DwmGetWindowAttribute(hwnd, attribute, out var value, sizeof(uint));
        if (result != 0 || value != expected)
            throw new InvalidOperationException($"Unexpected DWM attribute {attribute}: {value:X8}, HRESULT {result:X8}.");
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out uint value, int size);
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("user32.dll")]
    private static extern int GetWindowRgn(IntPtr hwnd, IntPtr region);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);
}
