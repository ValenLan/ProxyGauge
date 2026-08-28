using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using ProxyGauge.Models;

namespace ProxyGauge.Services;

public sealed class GuardClient
{
    private const string PipeName = "ProxyGauge.Guard.v1";
    private const string PipePath = @"\\.\pipe\" + PipeName;
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(3);

    private const uint GenericRead = 0x80000000;
    private const uint FileWriteData = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagOverlapped = 0x40000000;
    private const uint SecuritySqosPresent = 0x00100000;
    private const uint SecurityImpersonation = 0x00020000;
    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const uint ServiceStartPending = 0x00000002;
    private const uint ServiceRunning = 0x00000004;
    private const int ErrorFileNotFound = 2;
    private const int ErrorSemTimeout = 121;
    private const int ErrorPipeBusy = 231;

    public async Task<GuardStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            return GuardProtocol.ParseStatus(
                await SendAsync("STATUS", cancellationToken));
        }
        catch (Exception exception) when (
            exception is IOException or TimeoutException or OperationCanceledException or
            UnauthorizedAccessException or Win32Exception or GuardCommandException)
        {
            return GuardStatus.Unavailable(exception is GuardCommandException command
                ? command.Code
                : "SERVICE_UNAVAILABLE");
        }
    }

    public async Task EnableAsync(int mixedPort, CancellationToken cancellationToken = default)
    {
        var response = await SendAsync($"ENABLE\t{mixedPort}", cancellationToken);
        GuardProtocol.RequireSuccess(response, "ENABLE");
    }

    public async Task DisableAsync(CancellationToken cancellationToken = default)
    {
        var response = await SendAsync("DISABLE", cancellationToken);
        GuardProtocol.RequireSuccess(response, "DISABLE");
    }

    private static async Task<string> SendAsync(
        string command,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RequestTimeout);
        await using var pipe = await OpenTrustedPipeAsync(timeout.Token);

        var request = Encoding.Unicode.GetBytes(command + "\0");
        await pipe.WriteAsync(request, timeout.Token);
        await pipe.FlushAsync(timeout.Token);

        using var output = new MemoryStream();
        var buffer = new byte[1024];
        do
        {
            var bytesRead = await pipe.ReadAsync(buffer, timeout.Token);
            if (bytesRead == 0)
            {
                break;
            }
            output.Write(buffer, 0, bytesRead);
            if (output.Length > 8192)
            {
                throw new GuardCommandException("INVALID_RESPONSE");
            }

            var received = output.GetBuffer();
            var terminator = FindUnicodeTerminator(received, checked((int)output.Length));
            if (terminator >= 0)
            {
                return Encoding.Unicode.GetString(received, 0, terminator);
            }
        }
        while (true);

        throw new GuardCommandException("INVALID_RESPONSE");
    }

    private static async Task<NamedPipeClientStream> OpenTrustedPipeAsync(
        CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (WaitNamedPipeW(PipePath, 100))
            {
                var handle = CreateFileW(
                    PipePath,
                    GenericRead | FileWriteData,
                    0,
                    IntPtr.Zero,
                    OpenExisting,
                    FileFlagOverlapped | SecuritySqosPresent | SecurityImpersonation,
                    IntPtr.Zero);
                if (!handle.IsInvalid)
                {
                    try
                    {
                        VerifyGuardServiceServer(handle);
#pragma warning disable SYSLIB0063
                        return new NamedPipeClientStream(
                            PipeDirection.InOut,
                            isAsync: true,
                            isConnected: true,
                            handle);
#pragma warning restore SYSLIB0063
                    }
                    catch
                    {
                        handle.Dispose();
                        throw;
                    }
                }

                var openError = Marshal.GetLastWin32Error();
                handle.Dispose();
                if (openError != ErrorPipeBusy && openError != ErrorFileNotFound)
                {
                    throw new IOException(
                        "Unable to connect to ProxyGauge Guard.",
                        new Win32Exception(openError));
                }
            }
            else
            {
                var waitError = Marshal.GetLastWin32Error();
                if (waitError != ErrorPipeBusy &&
                    waitError != ErrorFileNotFound &&
                    waitError != ErrorSemTimeout)
                {
                    throw new IOException(
                        "Unable to wait for ProxyGauge Guard.",
                        new Win32Exception(waitError));
                }
            }

            await Task.Delay(50, cancellationToken);
        }
    }

    private static void VerifyGuardServiceServer(SafeFileHandle pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe, out var serverProcessId))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        var serviceManager = OpenSCManagerW(null, null, ScManagerConnect);
        if (serviceManager == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            var service = OpenServiceW(
                serviceManager,
                "ProxyGaugeGuard",
                ServiceQueryStatus);
            if (service == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                if (!QueryServiceStatusEx(
                        service,
                        0,
                        out var status,
                        (uint)Marshal.SizeOf<ServiceStatusProcess>(),
                        out _))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                if ((status.CurrentState != ServiceRunning &&
                     status.CurrentState != ServiceStartPending) ||
                    status.ProcessId != serverProcessId)
                {
                    throw new UnauthorizedAccessException(
                        "The ProxyGauge Guard pipe is not owned by the running Guard service.");
                }
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(serviceManager);
        }
    }

    private static int FindUnicodeTerminator(byte[] value, int length)
    {
        for (var index = 0; index + 1 < length; index += sizeof(char))
        {
            if (value[index] == 0 && value[index + 1] == 0)
            {
                return index;
            }
        }
        return -1;
    }

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    private static extern bool WaitNamedPipeW(string name, uint timeoutMilliseconds);

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(
        SafeFileHandle pipe,
        out uint serverProcessId);

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    private static extern IntPtr OpenSCManagerW(
        string? machineName,
        string? databaseName,
        uint desiredAccess);

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode,
        ExactSpelling = true,
        SetLastError = true)]
    private static extern IntPtr OpenServiceW(
        IntPtr serviceManager,
        string serviceName,
        uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool QueryServiceStatusEx(
        IntPtr service,
        int infoLevel,
        out ServiceStatusProcess status,
        uint bufferSize,
        out uint bytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr serviceHandle);

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
        public uint ProcessId;
        public uint ServiceFlags;
    }
}
