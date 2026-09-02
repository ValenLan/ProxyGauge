using System.Runtime.InteropServices;

namespace ProxyGauge.Services;

internal sealed class RouteChangeMonitor : IDisposable
{
    private const ushort AfUnspec = 0;
    private const uint NoError = 0;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RouteChangeCallback(
        IntPtr callerContext,
        IntPtr routeRow,
        MibNotificationType notificationType);

    private enum MibNotificationType
    {
        ParameterNotification = 0,
        AddInstance = 1,
        DeleteInstance = 2,
        InitialNotification = 3
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint NotifyRouteChange2(
        ushort addressFamily,
        RouteChangeCallback callback,
        IntPtr callerContext,
        [MarshalAs(UnmanagedType.U1)] bool initialNotification,
        out IntPtr notificationHandle);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint CancelMibChangeNotify2(IntPtr notificationHandle);

    private readonly object _startLock = new();
    private readonly Action _routeChanged;
    private readonly RouteChangeCallback _callback;
    private IntPtr _notificationHandle;
    private int _disposed;

    public RouteChangeMonitor(Action routeChanged)
    {
        ArgumentNullException.ThrowIfNull(routeChanged);
        _routeChanged = routeChanged;
        _callback = HandleRouteChange;
    }

    internal bool IsStarted =>
        Interlocked.CompareExchange(
            ref _notificationHandle,
            IntPtr.Zero,
            IntPtr.Zero) != IntPtr.Zero;

    public bool Start()
    {
        if (!OperatingSystem.IsWindows() || Volatile.Read(ref _disposed) != 0)
        {
            return false;
        }

        lock (_startLock)
        {
            if (_disposed != 0)
            {
                return false;
            }
            if (_notificationHandle != IntPtr.Zero)
            {
                return true;
            }

            uint result;
            IntPtr notificationHandle;
            try
            {
                result = NotifyRouteChange2(
                    AfUnspec,
                    _callback,
                    IntPtr.Zero,
                    initialNotification: false,
                    out notificationHandle);
            }
            catch (DllNotFoundException)
            {
                return false;
            }
            catch (EntryPointNotFoundException)
            {
                return false;
            }
            catch (BadImageFormatException)
            {
                return false;
            }
            if (result != NoError || notificationHandle == IntPtr.Zero)
            {
                return false;
            }

            _notificationHandle = notificationHandle;
            return true;
        }
    }

    private void HandleRouteChange(
        IntPtr callerContext,
        IntPtr routeRow,
        MibNotificationType notificationType)
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return;
        }

        try
        {
            _routeChanged();
        }
        catch
        {
            // Exceptions must never cross the unmanaged callback boundary.
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        IntPtr notificationHandle;
        lock (_startLock)
        {
            notificationHandle = _notificationHandle;
            _notificationHandle = IntPtr.Zero;
        }

        if (notificationHandle != IntPtr.Zero)
        {
            _ = CancelMibChangeNotify2(notificationHandle);
        }
        GC.KeepAlive(_callback);
    }
}
