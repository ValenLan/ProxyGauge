using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace ProxyGauge.Services;

internal enum TcpListenerAttribution
{
    Closed,
    MihomoOwned,
    OtherOrUnknown
}

internal static class TcpListenerOwnership
{
    private const uint NoError = 0;
    private const uint ErrorInsufficientBuffer = 122;
    private const int AddressFamilyInet = 2;
    private const int AddressFamilyInet6 = 23;

    private enum TcpTableClass
    {
        OwnerPidListener = 3,
        OwnerPidConnections = 4
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TcpRowOwnerPid
    {
        public uint State;
        public uint LocalAddress;
        public uint LocalPort;
        public uint RemoteAddress;
        public uint RemotePort;
        public uint OwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Tcp6RowOwnerPid
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] LocalAddress;
        public uint LocalScopeId;
        public uint LocalPort;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] RemoteAddress;
        public uint RemoteScopeId;
        public uint RemotePort;
        public uint State;
        public uint OwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TcpTableOwnerPidHeader
    {
        public uint Count;
        public TcpRowOwnerPid FirstRow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Tcp6TableOwnerPidHeader
    {
        public uint Count;
        public Tcp6RowOwnerPid FirstRow;
    }

    private static readonly int TcpFirstRowOffset = Marshal.OffsetOf<TcpTableOwnerPidHeader>(
        nameof(TcpTableOwnerPidHeader.FirstRow)).ToInt32();
    private static readonly int Tcp6FirstRowOffset = Marshal.OffsetOf<Tcp6TableOwnerPidHeader>(
        nameof(Tcp6TableOwnerPidHeader.FirstRow)).ToInt32();

    [DllImport("iphlpapi.dll", ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint GetExtendedTcpTable(
        IntPtr tcpTable,
        ref int size,
        [MarshalAs(UnmanagedType.Bool)] bool order,
        int addressFamily,
        TcpTableClass tableClass,
        uint reserved);

    internal static bool IsOwnedByAny(string host, int port, IReadOnlySet<int> processIds)
    {
        if (!OperatingSystem.IsWindows() || processIds.Count == 0 || port is < 1 or > 65535 ||
            !LocalEndpointPolicy.IsLoopbackHost(host))
        {
            return false;
        }

        try
        {
            var requestedAddress = IPAddress.Parse(LocalEndpointPolicy.NormalizeLoopbackHost(host));
            return GetOwners(requestedAddress, port).Any(processIds.Contains);
        }
        catch
        {
            return false;
        }
    }

    internal static async Task<TcpListenerAttribution> ProbeAsync(
        string host,
        int port,
        IReadOnlySet<int> processIds,
        int timeoutSeconds,
        CancellationToken cancellationToken = default)
    {
        if (!LocalEndpointPolicy.IsLoopbackHost(host) || port is < 1 or > 65535)
        {
            return TcpListenerAttribution.Closed;
        }

        try
        {
            var address = IPAddress.Parse(LocalEndpointPolicy.NormalizeLoopbackHost(host));
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutSeconds, 1, 30)));
            using var client = new TcpClient(address.AddressFamily);
            await client.ConnectAsync(address, port, timeout.Token);
            cancellationToken.ThrowIfCancellationRequested();
            var ownedByExpectedProcess = processIds.Count > 0 &&
                IsConnectedServerOwnedByAny(client, processIds);
            return Classify(client.Connected, ownedByExpectedProcess);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return TcpListenerAttribution.Closed;
        }
    }

    internal static TcpListenerAttribution Classify(
        bool canConnect,
        bool ownedByMihomo) =>
        !canConnect
            ? TcpListenerAttribution.Closed
            : ownedByMihomo
                ? TcpListenerAttribution.MihomoOwned
                : TcpListenerAttribution.OtherOrUnknown;

    private static IEnumerable<int> GetOwners(IPAddress requestedAddress, int port)
    {
        var addressFamily = requestedAddress.AddressFamily == AddressFamily.InterNetwork
            ? AddressFamilyInet
            : AddressFamilyInet6;
        if (requestedAddress.AddressFamily == AddressFamily.InterNetwork)
        {
            foreach (var row in GetRows<TcpRowOwnerPid>(
                         addressFamily,
                         TcpTableClass.OwnerPidListener,
                         TcpFirstRowOffset))
            {
                var localAddress = new IPAddress(BitConverter.GetBytes(row.LocalAddress));
                if (DecodePort(row.LocalPort) == port &&
                    (localAddress.Equals(IPAddress.Any) || localAddress.Equals(requestedAddress)))
                {
                    yield return checked((int)row.OwningPid);
                }
            }
            yield break;
        }

        foreach (var row in GetRows<Tcp6RowOwnerPid>(
                     addressFamily,
                     TcpTableClass.OwnerPidListener,
                     Tcp6FirstRowOffset))
        {
            var localAddress = new IPAddress(row.LocalAddress, row.LocalScopeId);
            if (DecodePort(row.LocalPort) == port &&
                (localAddress.Equals(IPAddress.IPv6Any) || localAddress.Equals(requestedAddress)))
            {
                yield return checked((int)row.OwningPid);
            }
        }
    }

    private static bool IsConnectedServerOwnedByAny(
        TcpClient client,
        IReadOnlySet<int> processIds)
    {
        if (client.Client.LocalEndPoint is not IPEndPoint clientEndpoint ||
            client.Client.RemoteEndPoint is not IPEndPoint serverEndpoint)
        {
            return false;
        }

        try
        {
            return GetConnectionOwners(clientEndpoint, serverEndpoint).Any(processIds.Contains);
        }
        catch
        {
            return false;
        }
    }

    private static IEnumerable<int> GetConnectionOwners(
        IPEndPoint clientEndpoint,
        IPEndPoint serverEndpoint)
    {
        foreach (var row in GetRows<TcpRowOwnerPid>(
                     AddressFamilyInet,
                     TcpTableClass.OwnerPidConnections,
                     TcpFirstRowOffset))
        {
            var localAddress = new IPAddress(BitConverter.GetBytes(row.LocalAddress));
            var remoteAddress = new IPAddress(BitConverter.GetBytes(row.RemoteAddress));
            if (MatchesServerConnection(
                    localAddress,
                    DecodePort(row.LocalPort),
                    remoteAddress,
                    DecodePort(row.RemotePort),
                    clientEndpoint,
                    serverEndpoint))
            {
                yield return checked((int)row.OwningPid);
            }
        }

        foreach (var row in GetRows<Tcp6RowOwnerPid>(
                     AddressFamilyInet6,
                     TcpTableClass.OwnerPidConnections,
                     Tcp6FirstRowOffset))
        {
            var localAddress = new IPAddress(row.LocalAddress, row.LocalScopeId);
            var remoteAddress = new IPAddress(row.RemoteAddress, row.RemoteScopeId);
            if (MatchesServerConnection(
                    localAddress,
                    DecodePort(row.LocalPort),
                    remoteAddress,
                    DecodePort(row.RemotePort),
                    clientEndpoint,
                    serverEndpoint))
            {
                yield return checked((int)row.OwningPid);
            }
        }
    }

    private static bool MatchesServerConnection(
        IPAddress localAddress,
        int localPort,
        IPAddress remoteAddress,
        int remotePort,
        IPEndPoint clientEndpoint,
        IPEndPoint serverEndpoint) =>
        localPort == serverEndpoint.Port &&
        remotePort == clientEndpoint.Port &&
        AddressesEqual(localAddress, serverEndpoint.Address) &&
        AddressesEqual(remoteAddress, clientEndpoint.Address);

    private static bool AddressesEqual(IPAddress first, IPAddress second)
    {
        if (first.IsIPv4MappedToIPv6)
        {
            first = first.MapToIPv4();
        }
        if (second.IsIPv4MappedToIPv6)
        {
            second = second.MapToIPv4();
        }
        return first.Equals(second);
    }

    private static IEnumerable<TRow> GetRows<TRow>(
        int addressFamily,
        TcpTableClass tableClass,
        int firstRowOffset)
        where TRow : struct
    {
        var size = 0;
        var firstResult = GetExtendedTcpTable(
            IntPtr.Zero,
            ref size,
            true,
            addressFamily,
            tableClass,
            0);
        if (firstResult != ErrorInsufficientBuffer || size <= firstRowOffset)
        {
            yield break;
        }

        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            var result = GetExtendedTcpTable(
                buffer,
                ref size,
                true,
                addressFamily,
                tableClass,
                0);
            if (result != NoError || size <= firstRowOffset)
            {
                yield break;
            }

            var rowCount = Marshal.ReadInt32(buffer);
            if (rowCount < 0 || rowCount > 1_000_000)
            {
                yield break;
            }

            var rowPointer = IntPtr.Add(buffer, firstRowOffset);
            var rowSize = Marshal.SizeOf<TRow>();
            if (rowCount > (size - firstRowOffset) / rowSize)
            {
                yield break;
            }
            for (var index = 0; index < rowCount; index++)
            {
                var current = IntPtr.Add(rowPointer, checked(index * rowSize));
                yield return Marshal.PtrToStructure<TRow>(current);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    internal static int DecodePort(uint networkOrderPort)
    {
        var bytes = BitConverter.GetBytes(networkOrderPort);
        return (bytes[0] << 8) | bytes[1];
    }
}
