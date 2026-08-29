#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <aclapi.h>
#include <fwpmu.h>
#include <iphlpapi.h>
#include <rpc.h>
#include <sddl.h>

#include <algorithm>
#include <atomic>
#include <cwctype>
#include <iostream>
#include <iterator>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace
{
constexpr wchar_t ServiceName[] = L"ProxyGaugeGuard";
constexpr wchar_t ServiceDisplayName[] = L"ProxyGauge Guard Service";
constexpr wchar_t PipeName[] = L"\\\\.\\pipe\\ProxyGauge.Guard.v1";
constexpr wchar_t RegistryPath[] = L"SOFTWARE\\ProxyGauge\\Guard";

// These keys are part of the on-disk WFP contract. Never regenerate them during an upgrade.
constexpr GUID ProviderKey =
    {0x310ec571, 0x3a57, 0x4341, {0xa2, 0x80, 0x00, 0x3e, 0xed, 0x39, 0x65, 0xd0}};
constexpr GUID SubLayerKey =
    {0xecf16b51, 0x4f93, 0x4b61, {0xb4, 0x58, 0x2c, 0xf8, 0x3e, 0xd3, 0x5e, 0x02}};

constexpr DWORD PipeBufferSize = 4096;
constexpr DWORD PipeTimeoutMilliseconds = 5000;
constexpr DWORD ReconcileIntervalMilliseconds = 5000;

SERVICE_STATUS_HANDLE serviceStatusHandle = nullptr;
SERVICE_STATUS serviceStatus{};
HANDLE stopEvent = nullptr;
std::atomic_bool stopping = false;
std::atomic<DWORD> fatalServiceError = NO_ERROR;

struct GuardState
{
    bool enabled = false;
    bool valid = true;
    std::wstring ownerSid;
    std::wstring proxyPath;
    DWORD mixedPort = 0;
};

struct ClientIdentity
{
    std::vector<BYTE> sid;
    std::wstring sidString;
    bool administrator = false;
};

class LocalMemory final
{
public:
    LocalMemory() = default;
    explicit LocalMemory(void* value) : value_(value) {}
    ~LocalMemory()
    {
        if (value_ != nullptr)
        {
            LocalFree(value_);
        }
    }

    LocalMemory(const LocalMemory&) = delete;
    LocalMemory& operator=(const LocalMemory&) = delete;

    void* get() const { return value_; }
    void** address() { return &value_; }

private:
    void* value_ = nullptr;
};

class EngineHandle final
{
public:
    ~EngineHandle()
    {
        if (value_ != nullptr)
        {
            FwpmEngineClose0(value_);
        }
    }

    HANDLE get() const { return value_; }
    HANDLE* address() { return &value_; }

private:
    HANDLE value_ = nullptr;
};

std::wstring ErrorText(DWORD error)
{
    wchar_t* message = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        error,
        0,
        reinterpret_cast<wchar_t*>(&message),
        0,
        nullptr);
    LocalMemory memory(message);
    if (length == 0 || message == nullptr)
    {
        return L"Windows error " + std::to_wstring(error);
    }

    std::wstring result(message, length);
    while (!result.empty() && (result.back() == L'\r' || result.back() == L'\n' || result.back() == L' '))
    {
        result.pop_back();
    }
    return result;
}

void ReportServiceStatus(DWORD state, DWORD error = NO_ERROR, DWORD waitHint = 0)
{
    serviceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    serviceStatus.dwCurrentState = state;
    serviceStatus.dwWin32ExitCode = error;
    serviceStatus.dwWaitHint = waitHint;
    serviceStatus.dwControlsAccepted = state == SERVICE_RUNNING
        ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
        : 0;
    serviceStatus.dwCheckPoint = state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING
        ? serviceStatus.dwCheckPoint + 1
        : 0;
    if (serviceStatusHandle != nullptr)
    {
        SetServiceStatus(serviceStatusHandle, &serviceStatus);
    }
}

bool ReadRegistryString(HKEY key, const wchar_t* name, std::wstring& value)
{
    DWORD type = 0;
    DWORD size = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) != ERROR_SUCCESS ||
        type != REG_SZ || size < sizeof(wchar_t))
    {
        return false;
    }

    std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
    if (RegQueryValueExW(
            key,
            name,
            nullptr,
            &type,
            reinterpret_cast<BYTE*>(buffer.data()),
            &size) != ERROR_SUCCESS)
    {
        return false;
    }
    value.assign(buffer.data());
    return true;
}

GuardState LoadState()
{
    GuardState state;
    HKEY rawKey = nullptr;
    const LONG openResult = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE, RegistryPath, 0, KEY_QUERY_VALUE, &rawKey);
    if (openResult == ERROR_FILE_NOT_FOUND)
    {
        return state;
    }
    if (openResult != ERROR_SUCCESS)
    {
        state.enabled = true;
        state.valid = false;
        return state;
    }

    DWORD enabled = 0;
    DWORD enabledSize = static_cast<DWORD>(sizeof(enabled));
    DWORD enabledType = 0;
    const LONG enabledResult = RegQueryValueExW(
            rawKey,
            L"Enabled",
            nullptr,
            &enabledType,
            reinterpret_cast<BYTE*>(&enabled),
            &enabledSize);
    if (enabledResult == ERROR_SUCCESS && enabledType == REG_DWORD &&
        enabledSize == sizeof(enabled) && enabled <= 1)
    {
        state.enabled = enabled == 1;
    }
    else if (enabledResult != ERROR_FILE_NOT_FOUND)
    {
        // An unreadable state must never be interpreted as permission to remove active filters.
        state.enabled = true;
        state.valid = false;
    }

    ReadRegistryString(rawKey, L"OwnerSid", state.ownerSid);
    ReadRegistryString(rawKey, L"ProxyPath", state.proxyPath);

    DWORD portSize = static_cast<DWORD>(sizeof(state.mixedPort));
    DWORD portType = 0;
    if (RegQueryValueExW(
            rawKey,
            L"MixedPort",
            nullptr,
            &portType,
            reinterpret_cast<BYTE*>(&state.mixedPort),
            &portSize) != ERROR_SUCCESS ||
        portType != REG_DWORD)
    {
        state.mixedPort = 0;
    }

    RegCloseKey(rawKey);
    if (state.enabled && (state.ownerSid.empty() || state.proxyPath.empty() ||
        state.mixedPort == 0 || state.mixedPort > 65535))
    {
        state.valid = false;
    }
    return state;
}

DWORD SaveState(const GuardState& state)
{
    HKEY rawKey = nullptr;
    DWORD disposition = 0;
    DWORD result = RegCreateKeyExW(
        HKEY_LOCAL_MACHINE,
        RegistryPath,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        &rawKey,
        &disposition);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    const DWORD enabled = state.enabled ? 1 : 0;
    result = RegSetValueExW(
        rawKey,
        L"Enabled",
        0,
        REG_DWORD,
        reinterpret_cast<const BYTE*>(&enabled),
        static_cast<DWORD>(sizeof(enabled)));
    if (result == ERROR_SUCCESS)
    {
        result = RegSetValueExW(
            rawKey,
            L"OwnerSid",
            0,
            REG_SZ,
            reinterpret_cast<const BYTE*>(state.ownerSid.c_str()),
            static_cast<DWORD>((state.ownerSid.size() + 1) * sizeof(wchar_t)));
    }
    if (result == ERROR_SUCCESS)
    {
        result = RegSetValueExW(
            rawKey,
            L"ProxyPath",
            0,
            REG_SZ,
            reinterpret_cast<const BYTE*>(state.proxyPath.c_str()),
            static_cast<DWORD>((state.proxyPath.size() + 1) * sizeof(wchar_t)));
    }
    if (result == ERROR_SUCCESS)
    {
        result = RegSetValueExW(
            rawKey,
            L"MixedPort",
            0,
            REG_DWORD,
            reinterpret_cast<const BYTE*>(&state.mixedPort),
            static_cast<DWORD>(sizeof(state.mixedPort)));
    }

    RegCloseKey(rawKey);
    return result;
}

std::optional<std::wstring> ProcessPath(DWORD processId)
{
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (process == nullptr)
    {
        return std::nullopt;
    }

    std::vector<wchar_t> buffer(32768);
    DWORD size = static_cast<DWORD>(buffer.size());
    const BOOL found = QueryFullProcessImageNameW(process, 0, buffer.data(), &size);
    CloseHandle(process);
    if (!found || size == 0)
    {
        return std::nullopt;
    }
    return std::wstring(buffer.data(), size);
}

template <typename Table, typename Row>
std::optional<std::wstring> FindTcpListenerPathForFamily(USHORT port, ULONG family)
{
    DWORD size = 0;
    const TCP_TABLE_CLASS tableClass = TCP_TABLE_OWNER_PID_LISTENER;
    DWORD result = GetExtendedTcpTable(nullptr, &size, FALSE, family, tableClass, 0);
    if (result != ERROR_INSUFFICIENT_BUFFER)
    {
        return std::nullopt;
    }

    std::vector<BYTE> buffer(size);
    result = GetExtendedTcpTable(buffer.data(), &size, FALSE, family, tableClass, 0);
    if (result != NO_ERROR)
    {
        return std::nullopt;
    }

    const auto* table = reinterpret_cast<const Table*>(buffer.data());
    for (DWORD index = 0; index < table->dwNumEntries; ++index)
    {
        const Row& row = table->table[index];
        if (ntohs(static_cast<u_short>(row.dwLocalPort)) != port)
        {
            continue;
        }
        if (auto path = ProcessPath(row.dwOwningPid); path.has_value())
        {
            return path;
        }
    }
    return std::nullopt;
}

std::optional<std::wstring> FindTcpListenerPath(USHORT port)
{
    auto path = FindTcpListenerPathForFamily<MIB_TCPTABLE_OWNER_PID, MIB_TCPROW_OWNER_PID>(port, AF_INET);
    if (!path.has_value())
    {
        path = FindTcpListenerPathForFamily<MIB_TCP6TABLE_OWNER_PID, MIB_TCP6ROW_OWNER_PID>(port, AF_INET6);
    }
    if (path.has_value() && GetFileAttributesW(path->c_str()) != INVALID_FILE_ATTRIBUTES)
    {
        return path;
    }
    return std::nullopt;
}

std::wstring Lower(std::wstring value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t character)
    {
        return static_cast<wchar_t>(std::towlower(character));
    });
    return value;
}

bool HasTunKeyword(const IP_ADAPTER_ADDRESSES& adapter)
{
    std::wstring text;
    if (adapter.FriendlyName != nullptr)
    {
        text.append(adapter.FriendlyName);
    }
    text.push_back(L' ');
    if (adapter.Description != nullptr)
    {
        text.append(adapter.Description);
    }
    text = Lower(std::move(text));
    constexpr const wchar_t* keywords[] =
    {
        L"wintun", L"wireguard", L"mihomo", L"clash", L"sing-box", L"singbox", L" tun"
    };
    return std::any_of(std::begin(keywords), std::end(keywords), [&](const wchar_t* keyword)
    {
        return text.find(keyword) != std::wstring::npos;
    });
}

std::set<UINT64> FakeIpRouteInterfaces()
{
    std::set<UINT64> result;
    MIB_IPFORWARD_TABLE2* table = nullptr;
    if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || table == nullptr)
    {
        return result;
    }

    IN_ADDR targetAddress{};
    InetPtonW(AF_INET, L"198.18.0.1", &targetAddress);
    const ULONG target = ntohl(targetAddress.S_un.S_addr);
    for (ULONG index = 0; index < table->NumEntries; ++index)
    {
        const MIB_IPFORWARD_ROW2& row = table->Table[index];
        const UINT8 prefixLength = row.DestinationPrefix.PrefixLength;
        if (prefixLength < 15 || prefixLength > 32 ||
            row.DestinationPrefix.Prefix.si_family != AF_INET)
        {
            continue;
        }
        const ULONG destination = ntohl(
            row.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr);
        const ULONG mask = prefixLength == 32
            ? 0xffffffffUL
            : 0xffffffffUL << (32 - prefixLength);
        if ((target & mask) == (destination & mask) && row.InterfaceLuid.Value != 0)
        {
            result.insert(row.InterfaceLuid.Value);
        }
    }
    FreeMibTable(table);
    return result;
}

std::vector<UINT64> FindTunInterfaces()
{
    ULONG size = 0;
    GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr, nullptr, &size);
    if (size == 0)
    {
        return {};
    }

    std::vector<BYTE> buffer(size);
    auto* addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    if (GetAdaptersAddresses(
            AF_UNSPEC,
            GAA_FLAG_INCLUDE_ALL_INTERFACES,
            nullptr,
            addresses,
            &size) != NO_ERROR)
    {
        return {};
    }

    std::set<UINT64> luids = FakeIpRouteInterfaces();
    for (auto* adapter = addresses; adapter != nullptr; adapter = adapter->Next)
    {
        if (adapter->OperStatus != IfOperStatusUp || adapter->Luid.Value == 0 ||
            adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK)
        {
            continue;
        }
        if (adapter->IfType == IF_TYPE_TUNNEL || HasTunKeyword(*adapter))
        {
            luids.insert(adapter->Luid.Value);
        }
    }
    return std::vector<UINT64>(luids.begin(), luids.end());
}

DWORD OpenEngine(EngineHandle& engine)
{
    return FwpmEngineOpen0(
        nullptr,
        RPC_C_AUTHN_DEFAULT,
        nullptr,
        nullptr,
        engine.address());
}

DWORD EnsureProviderAndSubLayer(HANDLE engine)
{
    FWPM_PROVIDER0 provider{};
    provider.providerKey = ProviderKey;
    provider.displayData.name = const_cast<wchar_t*>(L"ProxyGauge Guard");
    provider.displayData.description = const_cast<wchar_t*>(
        L"Persistent outbound leak protection owned by ProxyGauge.");
    provider.flags = FWPM_PROVIDER_FLAG_PERSISTENT;
    provider.serviceName = const_cast<wchar_t*>(ServiceName);
    DWORD result = FwpmProviderAdd0(engine, &provider, nullptr);
    if (result != ERROR_SUCCESS && result != FWP_E_ALREADY_EXISTS)
    {
        return result;
    }

    FWPM_SUBLAYER0 subLayer{};
    subLayer.subLayerKey = SubLayerKey;
    subLayer.displayData.name = const_cast<wchar_t*>(L"ProxyGauge Guard");
    subLayer.displayData.description = const_cast<wchar_t*>(
        L"ProxyGauge per-user fail-closed outbound rules.");
    subLayer.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    subLayer.providerKey = const_cast<GUID*>(&ProviderKey);
    subLayer.weight = 0x7000;
    result = FwpmSubLayerAdd0(engine, &subLayer, nullptr);
    return result == FWP_E_ALREADY_EXISTS ? ERROR_SUCCESS : result;
}

DWORD DeleteProviderFiltersAtLayer(HANDLE engine, const GUID& layer)
{
    FWPM_FILTER_ENUM_TEMPLATE0 filterTemplate{};
    filterTemplate.providerKey = const_cast<GUID*>(&ProviderKey);
    filterTemplate.layerKey = layer;
    filterTemplate.actionMask = 0xffffffff;
    HANDLE enumHandle = nullptr;
    DWORD result = FwpmFilterCreateEnumHandle0(engine, &filterTemplate, &enumHandle);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    for (;;)
    {
        FWPM_FILTER0** filters = nullptr;
        UINT32 count = 0;
        result = FwpmFilterEnum0(engine, enumHandle, 128, &filters, &count);
        if (result != ERROR_SUCCESS)
        {
            FwpmFilterDestroyEnumHandle0(engine, enumHandle);
            return result;
        }
        for (UINT32 index = 0; index < count; ++index)
        {
            result = FwpmFilterDeleteByKey0(engine, &filters[index]->filterKey);
            if (result != ERROR_SUCCESS && result != FWP_E_FILTER_NOT_FOUND)
            {
                FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
                FwpmFilterDestroyEnumHandle0(engine, enumHandle);
                return result;
            }
        }
        FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
        if (count < 128)
        {
            break;
        }
    }
    FwpmFilterDestroyEnumHandle0(engine, enumHandle);
    return ERROR_SUCCESS;
}

DWORD DeleteProviderFilters(HANDLE engine)
{
    DWORD result = DeleteProviderFiltersAtLayer(engine, FWPM_LAYER_ALE_AUTH_CONNECT_V4);
    if (result == ERROR_SUCCESS)
    {
        result = DeleteProviderFiltersAtLayer(engine, FWPM_LAYER_ALE_AUTH_CONNECT_V6);
    }
    return result;
}

DWORD CountProviderFiltersAtLayer(HANDLE engine, const GUID& layer, UINT32& count)
{
    count = 0;
    FWPM_FILTER_ENUM_TEMPLATE0 filterTemplate{};
    filterTemplate.providerKey = const_cast<GUID*>(&ProviderKey);
    filterTemplate.layerKey = layer;
    filterTemplate.actionMask = 0xffffffff;
    HANDLE enumHandle = nullptr;
    DWORD result = FwpmFilterCreateEnumHandle0(engine, &filterTemplate, &enumHandle);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    for (;;)
    {
        FWPM_FILTER0** filters = nullptr;
        UINT32 batchCount = 0;
        result = FwpmFilterEnum0(engine, enumHandle, 128, &filters, &batchCount);
        if (result != ERROR_SUCCESS)
        {
            FwpmFilterDestroyEnumHandle0(engine, enumHandle);
            return result;
        }
        count += batchCount;
        FwpmFreeMemory0(reinterpret_cast<void**>(&filters));
        if (batchCount < 128)
        {
            break;
        }
    }
    FwpmFilterDestroyEnumHandle0(engine, enumHandle);
    return ERROR_SUCCESS;
}


DWORD CountProviderFilters(UINT32& count)
{
    count = 0;
    EngineHandle engine;
    DWORD result = OpenEngine(engine);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    UINT32 ipv4Count = 0;
    UINT32 ipv6Count = 0;
    result = CountProviderFiltersAtLayer(
        engine.get(), FWPM_LAYER_ALE_AUTH_CONNECT_V4, ipv4Count);
    if (result == ERROR_SUCCESS)
    {
        result = CountProviderFiltersAtLayer(
            engine.get(), FWPM_LAYER_ALE_AUTH_CONNECT_V6, ipv6Count);
    }
    count = ipv4Count + ipv6Count;
    return result;
}

DWORD BuildUserSecurityDescriptor(PSID sid, LocalMemory& descriptor, FWP_BYTE_BLOB& blob)
{
    EXPLICIT_ACCESSW access{};
    access.grfAccessPermissions = FWP_ACTRL_MATCH_FILTER;
    access.grfAccessMode = GRANT_ACCESS;
    access.grfInheritance = NO_INHERITANCE;
    BuildTrusteeWithSidW(&access.Trustee, sid);

    ULONG size = 0;
    PSECURITY_DESCRIPTOR value = nullptr;
    DWORD result = BuildSecurityDescriptorW(
        nullptr,
        nullptr,
        1,
        &access,
        0,
        nullptr,
        nullptr,
        &size,
        &value);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    *descriptor.address() = value;
    blob.size = size;
    blob.data = static_cast<UINT8*>(value);
    return ERROR_SUCCESS;
}

DWORD AddFilter(
    HANDLE engine,
    const GUID& layer,
    const wchar_t* name,
    FWP_ACTION_TYPE action,
    UINT64 weightValue,
    FWPM_FILTER_CONDITION0* conditions,
    UINT32 conditionCount)
{
    FWPM_FILTER0 filter{};
    filter.displayData.name = const_cast<wchar_t*>(name);
    filter.flags = FWPM_FILTER_FLAG_PERSISTENT;
    filter.providerKey = const_cast<GUID*>(&ProviderKey);
    filter.layerKey = layer;
    filter.subLayerKey = SubLayerKey;
    filter.weight.type = FWP_UINT64;
    filter.weight.uint64 = &weightValue;
    filter.numFilterConditions = conditionCount;
    filter.filterCondition = conditions;
    filter.action.type = action;
    return FwpmFilterAdd0(engine, &filter, nullptr, nullptr);
}

DWORD InstallFilters(PSID ownerSid, const std::wstring& proxyPath, const std::vector<UINT64>& tunLuids)
{
    if (!IsValidSid(ownerSid) || proxyPath.empty())
    {
        return ERROR_INVALID_PARAMETER;
    }

    EngineHandle engine;
    DWORD result = OpenEngine(engine);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }
    result = EnsureProviderAndSubLayer(engine.get());
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    LocalMemory securityDescriptor;
    FWP_BYTE_BLOB securityBlob{};
    result = BuildUserSecurityDescriptor(ownerSid, securityDescriptor, securityBlob);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    FWP_BYTE_BLOB* appId = nullptr;
    result = FwpmGetAppIdFromFileName0(proxyPath.c_str(), &appId);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    result = FwpmTransactionBegin0(engine.get(), 0);
    if (result != ERROR_SUCCESS)
    {
        FwpmFreeMemory0(reinterpret_cast<void**>(&appId));
        return result;
    }

    auto abort = [&]()
    {
        FwpmTransactionAbort0(engine.get());
        FwpmFreeMemory0(reinterpret_cast<void**>(&appId));
    };

    result = DeleteProviderFilters(engine.get());
    if (result != ERROR_SUCCESS)
    {
        abort();
        return result;
    }

    FWPM_FILTER_CONDITION0 userCondition{};
    userCondition.fieldKey = FWPM_CONDITION_ALE_USER_ID;
    userCondition.matchType = FWP_MATCH_EQUAL;
    userCondition.conditionValue.type = FWP_SECURITY_DESCRIPTOR_TYPE;
    userCondition.conditionValue.sd = &securityBlob;

    constexpr UINT64 PermitWeight = 0xf000000000000000ULL;
    constexpr UINT64 BlockWeight = 0x1000000000000000ULL;
    const GUID layers[] = {FWPM_LAYER_ALE_AUTH_CONNECT_V4, FWPM_LAYER_ALE_AUTH_CONNECT_V6};
    const wchar_t* familyNames[] = {L"IPv4", L"IPv6"};

    for (size_t layerIndex = 0; layerIndex < std::size(layers); ++layerIndex)
    {
        FWPM_FILTER_CONDITION0 loopbackConditions[2] = {userCondition, {}};
        loopbackConditions[1].fieldKey = FWPM_CONDITION_FLAGS;
        loopbackConditions[1].matchType = FWP_MATCH_FLAGS_ALL_SET;
        loopbackConditions[1].conditionValue.type = FWP_UINT32;
        loopbackConditions[1].conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;
        const std::wstring loopbackName = std::wstring(L"ProxyGauge permit loopback ") + familyNames[layerIndex];
        result = AddFilter(
            engine.get(), layers[layerIndex], loopbackName.c_str(), FWP_ACTION_PERMIT,
            PermitWeight, loopbackConditions, 2);
        if (result != ERROR_SUCCESS)
        {
            abort();
            return result;
        }

        FWPM_FILTER_CONDITION0 appConditions[2] = {userCondition, {}};
        appConditions[1].fieldKey = FWPM_CONDITION_ALE_APP_ID;
        appConditions[1].matchType = FWP_MATCH_EQUAL;
        appConditions[1].conditionValue.type = FWP_BYTE_BLOB_TYPE;
        appConditions[1].conditionValue.byteBlob = appId;
        const std::wstring appName = std::wstring(L"ProxyGauge permit proxy core ") + familyNames[layerIndex];
        result = AddFilter(
            engine.get(), layers[layerIndex], appName.c_str(), FWP_ACTION_PERMIT,
            PermitWeight, appConditions, 2);
        if (result != ERROR_SUCCESS)
        {
            abort();
            return result;
        }

        for (const UINT64 luid : tunLuids)
        {
            UINT64 luidValue = luid;
            FWPM_FILTER_CONDITION0 tunConditions[2] = {userCondition, {}};
            tunConditions[1].fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
            tunConditions[1].matchType = FWP_MATCH_EQUAL;
            tunConditions[1].conditionValue.type = FWP_UINT64;
            tunConditions[1].conditionValue.uint64 = &luidValue;
            const std::wstring tunName = std::wstring(L"ProxyGauge permit TUN ") + familyNames[layerIndex];
            result = AddFilter(
                engine.get(), layers[layerIndex], tunName.c_str(), FWP_ACTION_PERMIT,
                PermitWeight, tunConditions, 2);
            if (result != ERROR_SUCCESS)
            {
                abort();
                return result;
            }
        }

        FWPM_FILTER_CONDITION0 blockConditions[1] = {userCondition};
        const std::wstring blockName = std::wstring(L"ProxyGauge block direct ") + familyNames[layerIndex];
        result = AddFilter(
            engine.get(), layers[layerIndex], blockName.c_str(), FWP_ACTION_BLOCK,
            BlockWeight, blockConditions, 1);
        if (result != ERROR_SUCCESS)
        {
            abort();
            return result;
        }
    }

    result = FwpmTransactionCommit0(engine.get());
    FwpmFreeMemory0(reinterpret_cast<void**>(&appId));
    return result;
}

DWORD RemoveFilters(bool removeObjects)
{
    EngineHandle engine;
    DWORD result = OpenEngine(engine);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }

    result = FwpmTransactionBegin0(engine.get(), 0);
    if (result != ERROR_SUCCESS)
    {
        return result;
    }
    result = DeleteProviderFilters(engine.get());
    if (result == ERROR_SUCCESS && removeObjects)
    {
        result = FwpmSubLayerDeleteByKey0(engine.get(), &SubLayerKey);
        if (result == FWP_E_SUBLAYER_NOT_FOUND)
        {
            result = ERROR_SUCCESS;
        }
        if (result == ERROR_SUCCESS)
        {
            result = FwpmProviderDeleteByKey0(engine.get(), &ProviderKey);
            if (result == FWP_E_PROVIDER_NOT_FOUND)
            {
                result = ERROR_SUCCESS;
            }
        }
    }
    if (result != ERROR_SUCCESS)
    {
        FwpmTransactionAbort0(engine.get());
        return result;
    }
    return FwpmTransactionCommit0(engine.get());
}

std::optional<std::vector<BYTE>> SidFromString(const std::wstring& value)
{
    PSID parsed = nullptr;
    if (!ConvertStringSidToSidW(value.c_str(), &parsed) || parsed == nullptr)
    {
        return std::nullopt;
    }
    LocalMemory memory(parsed);
    const DWORD length = GetLengthSid(parsed);
    std::vector<BYTE> result(length);
    if (!CopySid(length, result.data(), parsed))
    {
        return std::nullopt;
    }
    return result;
}

bool SameSid(const std::wstring& ownerSid, const ClientIdentity& identity)
{
    auto owner = SidFromString(ownerSid);
    return owner.has_value() &&
        EqualSid(owner->data(), const_cast<BYTE*>(identity.sid.data()));
}

std::optional<ClientIdentity> ReadClientIdentity(HANDLE pipe)
{
    if (!ImpersonateNamedPipeClient(pipe))
    {
        return std::nullopt;
    }

    HANDLE token = nullptr;
    if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token))
    {
        RevertToSelf();
        return std::nullopt;
    }

    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> tokenBuffer(size);
    if (size == 0 || !GetTokenInformation(token, TokenUser, tokenBuffer.data(), size, &size))
    {
        CloseHandle(token);
        RevertToSelf();
        return std::nullopt;
    }

    const auto* tokenUser = reinterpret_cast<const TOKEN_USER*>(tokenBuffer.data());
    const DWORD sidLength = GetLengthSid(tokenUser->User.Sid);
    ClientIdentity identity;
    identity.sid.resize(sidLength);
    if (!CopySid(sidLength, identity.sid.data(), tokenUser->User.Sid))
    {
        CloseHandle(token);
        RevertToSelf();
        return std::nullopt;
    }

    wchar_t* sidString = nullptr;
    if (!ConvertSidToStringSidW(identity.sid.data(), &sidString))
    {
        CloseHandle(token);
        RevertToSelf();
        return std::nullopt;
    }
    identity.sidString.assign(sidString);
    LocalFree(sidString);

    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID administrators = nullptr;
    BOOL isMember = FALSE;
    if (AllocateAndInitializeSid(
            &authority,
            2,
            SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS,
            0, 0, 0, 0, 0, 0,
            &administrators))
    {
        CheckTokenMembership(token, administrators, &isMember);
        FreeSid(administrators);
    }
    identity.administrator = isMember == TRUE;

    CloseHandle(token);
    RevertToSelf();
    return identity;
}

std::vector<std::wstring> Split(const std::wstring& value, wchar_t separator)
{
    std::vector<std::wstring> fields;
    size_t start = 0;
    while (start <= value.size())
    {
        const size_t end = value.find(separator, start);
        fields.push_back(value.substr(start, end == std::wstring::npos ? end : end - start));
        if (end == std::wstring::npos)
        {
            break;
        }
        start = end + 1;
    }
    return fields;
}

std::wstring ResponseError(const wchar_t* code, DWORD error = ERROR_SUCCESS)
{
    if (error == ERROR_SUCCESS)
    {
        return std::wstring(L"ERROR\t") + code;
    }
    return std::wstring(L"ERROR\t") + code + L"\t" + std::to_wstring(error);
}

class GuardController final
{
public:
    GuardController() : state_(LoadState()) {}

    void Reconcile()
    {
        std::lock_guard lock(mutex_);
        if (!state_.enabled)
        {
            UINT32 filterCount = 0;
            if (CountProviderFilters(filterCount) == ERROR_SUCCESS && filterCount != 0)
            {
                RemoveFilters(false);
            }
            return;
        }

        if (!state_.valid)
        {
            // Keep any persistent rules in place until the owner repairs state or an admin recovers.
            return;
        }

        auto sid = SidFromString(state_.ownerSid);
        if (!sid.has_value())
        {
            return;
        }
        auto currentPath = FindTcpListenerPath(static_cast<USHORT>(state_.mixedPort));
        if (currentPath.has_value())
        {
            state_.proxyPath = *currentPath;
        }

        const auto tunLuids = FindTunInterfaces();
        UINT32 filterCount = 0;
        const UINT32 expectedFilterCount = static_cast<UINT32>(6 + tunLuids.size() * 2);
        const bool filtersHealthy = CountProviderFilters(filterCount) == ERROR_SUCCESS &&
            filterCount == expectedFilterCount;
        if (filtersHealthy && state_.proxyPath == lastProxyPath_ && tunLuids == lastTunLuids_)
        {
            return;
        }

        if (InstallFilters(sid->data(), state_.proxyPath, tunLuids) == ERROR_SUCCESS)
        {
            lastProxyPath_ = state_.proxyPath;
            lastTunLuids_ = tunLuids;
            SaveState(state_);
        }
    }

    std::wstring Handle(const std::wstring& request, const ClientIdentity& identity)
    {
        std::lock_guard lock(mutex_);
        const auto fields = Split(request, L'\t');
        if (fields.empty())
        {
            return ResponseError(L"BAD_REQUEST");
        }

        if (fields[0] == L"STATUS")
        {
            UINT32 filterCount = 0;
            const DWORD statusError = CountProviderFilters(filterCount);
            const auto tunLuids = FindTunInterfaces();
            const UINT32 expectedFilterCount = static_cast<UINT32>(6 + tunLuids.size() * 2);
            const bool owned = !state_.enabled || SameSid(state_.ownerSid, identity);
            const bool healthy = state_.enabled && state_.valid &&
                statusError == ERROR_SUCCESS && filterCount == expectedFilterCount &&
                state_.proxyPath == lastProxyPath_ && tunLuids == lastTunLuids_;
            std::wostringstream response;
            response << L"OK\tSTATUS\t" << (state_.enabled ? L"ENABLED" : L"DISABLED")
                     << L'\t' << (healthy ? L"HEALTHY" : state_.enabled ? L"FAULT" : L"OFF")
                     << L'\t' << filterCount
                     << L'\t' << (owned ? L"OWNED" : L"FOREIGN");
            return response.str();
        }

        if (fields[0] == L"ENABLE")
        {
            if (fields.size() != 2)
            {
                return ResponseError(L"BAD_REQUEST");
            }
            wchar_t* end = nullptr;
            const unsigned long port = wcstoul(fields[1].c_str(), &end, 10);
            if (end == fields[1].c_str() || *end != L'\0' || port == 0 || port > 65535)
            {
                return ResponseError(L"INVALID_PORT");
            }
            if (state_.enabled && !SameSid(state_.ownerSid, identity) && !identity.administrator)
            {
                return ResponseError(L"OWNER_MISMATCH");
            }

            const auto proxyPath = FindTcpListenerPath(static_cast<USHORT>(port));
            if (!proxyPath.has_value())
            {
                return ResponseError(L"PROXY_NOT_LISTENING");
            }

            const auto tunLuids = FindTunInterfaces();
            const DWORD result = InstallFilters(
                const_cast<BYTE*>(identity.sid.data()),
                *proxyPath,
                tunLuids);
            if (result != ERROR_SUCCESS)
            {
                return ResponseError(L"WFP_ENABLE_FAILED", result);
            }

            GuardState next;
            next.enabled = true;
            next.ownerSid = identity.sidString;
            next.proxyPath = *proxyPath;
            next.mixedPort = static_cast<DWORD>(port);
            const DWORD saveResult = SaveState(next);
            state_ = next;
            lastProxyPath_ = next.proxyPath;
            lastTunLuids_ = tunLuids;
            if (saveResult != ERROR_SUCCESS)
            {
                // Fail closed: persistent filters remain active even if state persistence failed.
                state_.valid = false;
                return ResponseError(L"STATE_SAVE_FAILED", saveResult);
            }
            return L"OK\tENABLE";
        }

        if (fields[0] == L"DISABLE")
        {
            if (state_.enabled && !SameSid(state_.ownerSid, identity) && !identity.administrator)
            {
                return ResponseError(L"OWNER_MISMATCH");
            }
            const DWORD result = RemoveFilters(false);
            if (result != ERROR_SUCCESS)
            {
                return ResponseError(L"WFP_DISABLE_FAILED", result);
            }
            GuardState next;
            const DWORD saveResult = SaveState(next);
            if (saveResult != ERROR_SUCCESS)
            {
                state_.valid = false;
                return ResponseError(L"STATE_SAVE_FAILED", saveResult);
            }
            state_ = std::move(next);
            lastProxyPath_.clear();
            lastTunLuids_.clear();
            return L"OK\tDISABLE";
        }

        return ResponseError(L"BAD_REQUEST");
    }

private:
    std::mutex mutex_;
    GuardState state_;
    std::wstring lastProxyPath_;
    std::vector<UINT64> lastTunLuids_;
};

bool WaitForOverlapped(HANDLE pipe, OVERLAPPED& operation, DWORD timeout, DWORD& transferred)
{
    HANDLE handles[] = {operation.hEvent, stopEvent};
    const DWORD wait = WaitForMultipleObjects(2, handles, FALSE, timeout);
    if (wait != WAIT_OBJECT_0)
    {
        CancelIoEx(pipe, &operation);
        // CancelIoEx only requests cancellation. Keep the OVERLAPPED and its
        // event alive until the I/O manager has completed that request.
        GetOverlappedResult(pipe, &operation, &transferred, TRUE);
        return false;
    }
    return GetOverlappedResult(pipe, &operation, &transferred, FALSE) == TRUE;
}

bool ReadRequest(HANDLE pipe, std::wstring& request)
{
    std::vector<wchar_t> buffer(PipeBufferSize / sizeof(wchar_t));
    OVERLAPPED operation{};
    operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (operation.hEvent == nullptr)
    {
        return false;
    }

    DWORD transferred = 0;
    BOOL success = ReadFile(
        pipe,
        buffer.data(),
        PipeBufferSize - static_cast<DWORD>(sizeof(wchar_t)),
        nullptr,
        &operation);
    if (!success && GetLastError() == ERROR_IO_PENDING)
    {
        success = WaitForOverlapped(pipe, operation, PipeTimeoutMilliseconds, transferred);
    }
    else if (success)
    {
        success = GetOverlappedResult(pipe, &operation, &transferred, TRUE);
    }
    CloseHandle(operation.hEvent);
    if (!success || transferred == 0 || transferred % sizeof(wchar_t) != 0)
    {
        return false;
    }

    request.assign(buffer.data(), transferred / sizeof(wchar_t));
    while (!request.empty() && (request.back() == L'\0' || request.back() == L'\r' || request.back() == L'\n'))
    {
        request.pop_back();
    }
    return !request.empty();
}

bool WriteResponse(HANDLE pipe, const std::wstring& response)
{
    OVERLAPPED operation{};
    operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (operation.hEvent == nullptr)
    {
        return false;
    }

    const DWORD bytes = static_cast<DWORD>((response.size() + 1) * sizeof(wchar_t));
    DWORD transferred = 0;
    BOOL success = WriteFile(pipe, response.c_str(), bytes, nullptr, &operation);
    if (!success && GetLastError() == ERROR_IO_PENDING)
    {
        success = WaitForOverlapped(pipe, operation, PipeTimeoutMilliseconds, transferred);
    }
    else if (success)
    {
        success = GetOverlappedResult(pipe, &operation, &transferred, TRUE);
    }
    CloseHandle(operation.hEvent);
    return success == TRUE && transferred == bytes;
}

void WaitForClientClose(HANDLE pipe)
{
    BYTE unexpectedData = 0;
    OVERLAPPED operation{};
    operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (operation.hEvent == nullptr)
    {
        return;
    }

    DWORD transferred = 0;
    BOOL success = ReadFile(
        pipe,
        &unexpectedData,
        static_cast<DWORD>(sizeof(unexpectedData)),
        nullptr,
        &operation);
    if (!success && GetLastError() == ERROR_IO_PENDING)
    {
        WaitForOverlapped(pipe, operation, PipeTimeoutMilliseconds, transferred);
    }
    CloseHandle(operation.hEvent);
}

void PipeLoop(GuardController& controller)
{
    PSECURITY_DESCRIPTOR pipeDescriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            // FILE_GENERIC_WRITE also grants FILE_CREATE_PIPE_INSTANCE. Give
            // authenticated clients only generic read plus FILE_WRITE_DATA so
            // they cannot add a server instance to the Guard pipe.
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;AU)(A;;0x00000002;;;AU)",
            SDDL_REVISION_1,
            &pipeDescriptor,
            nullptr))
    {
        fatalServiceError.store(GetLastError());
        SetEvent(stopEvent);
        return;
    }
    LocalMemory descriptorMemory(pipeDescriptor);
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = static_cast<DWORD>(sizeof(attributes));
    attributes.lpSecurityDescriptor = pipeDescriptor;
    attributes.bInheritHandle = FALSE;

    HANDLE pipe = CreateNamedPipeW(
        PipeName,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1,
        PipeBufferSize,
        PipeBufferSize,
        0,
        &attributes);
    if (pipe == INVALID_HANDLE_VALUE)
    {
        fatalServiceError.store(GetLastError());
        SetEvent(stopEvent);
        return;
    }

    // Reuse the first instance for the service lifetime. Besides avoiding a
    // namespace gap between requests, this keeps the restrictive DACL alive.
    while (!stopping.load())
    {
        OVERLAPPED connection{};
        connection.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (connection.hEvent == nullptr)
        {
            fatalServiceError.store(GetLastError());
            SetEvent(stopEvent);
            break;
        }

        DWORD transferred = 0;
        BOOL connected = ConnectNamedPipe(pipe, &connection);
        if (!connected)
        {
            const DWORD error = GetLastError();
            if (error == ERROR_PIPE_CONNECTED)
            {
                connected = TRUE;
            }
            else if (error == ERROR_IO_PENDING)
            {
                connected = WaitForOverlapped(pipe, connection, INFINITE, transferred);
            }
        }
        CloseHandle(connection.hEvent);

        if (connected && !stopping.load())
        {
            std::wstring request;
            if (ReadRequest(pipe, request))
            {
                const auto identity = ReadClientIdentity(pipe);
                const std::wstring response = identity.has_value()
                    ? controller.Handle(request, *identity)
                    : ResponseError(L"IDENTITY_FAILED");
                if (WriteResponse(pipe, response))
                {
                    // Keep the message buffered until the client has consumed
                    // it and closed its end. DisconnectNamedPipe may otherwise
                    // discard unread response bytes.
                    WaitForClientClose(pipe);
                }
            }
        }
        DisconnectNamedPipe(pipe);
    }
    CloseHandle(pipe);
}

DWORD WINAPI ServiceControlHandler(DWORD control, DWORD, void*, void*)
{
    if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN)
    {
        ReportServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 10000);
        stopping.store(true);
        if (stopEvent != nullptr)
        {
            SetEvent(stopEvent);
        }
    }
    return NO_ERROR;
}

void WINAPI ServiceMain(DWORD, wchar_t**)
{
    serviceStatusHandle = RegisterServiceCtrlHandlerExW(
        ServiceName,
        ServiceControlHandler,
        nullptr);
    if (serviceStatusHandle == nullptr)
    {
        return;
    }
    ReportServiceStatus(SERVICE_START_PENDING, NO_ERROR, 15000);

    stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stopEvent == nullptr)
    {
        ReportServiceStatus(SERVICE_STOPPED, GetLastError());
        return;
    }

    GuardController controller;
    controller.Reconcile();
    std::thread pipeThread(PipeLoop, std::ref(controller));
    ReportServiceStatus(SERVICE_RUNNING);

    while (WaitForSingleObject(stopEvent, ReconcileIntervalMilliseconds) == WAIT_TIMEOUT)
    {
        controller.Reconcile();
    }

    stopping.store(true);
    SetEvent(stopEvent);
    if (pipeThread.joinable())
    {
        pipeThread.join();
    }
    CloseHandle(stopEvent);
    stopEvent = nullptr;
    ReportServiceStatus(SERVICE_STOPPED, fatalServiceError.load());
}

DWORD StopServiceForRecovery()
{
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (manager == nullptr)
    {
        return GetLastError();
    }

    SC_HANDLE service = OpenServiceW(
        manager,
        ServiceName,
        SERVICE_STOP | SERVICE_QUERY_STATUS);
    if (service == nullptr)
    {
        const DWORD error = GetLastError();
        CloseServiceHandle(manager);
        return error == ERROR_SERVICE_DOES_NOT_EXIST ? ERROR_SUCCESS : error;
    }

    auto queryStatus = [&](SERVICE_STATUS_PROCESS& status)
    {
        DWORD bytesNeeded = 0;
        return QueryServiceStatusEx(
            service,
            SC_STATUS_PROCESS_INFO,
            reinterpret_cast<LPBYTE>(&status),
            static_cast<DWORD>(sizeof(status)),
            &bytesNeeded) == TRUE;
    };

    SERVICE_STATUS_PROCESS status{};
    DWORD result = ERROR_SUCCESS;
    if (!queryStatus(status))
    {
        result = GetLastError();
    }
    else if (status.dwCurrentState != SERVICE_STOPPED)
    {
        if (status.dwCurrentState != SERVICE_STOP_PENDING)
        {
            SERVICE_STATUS ignored{};
            if (!ControlService(service, SERVICE_CONTROL_STOP, &ignored))
            {
                const DWORD stopError = GetLastError();
                if (stopError != ERROR_SERVICE_NOT_ACTIVE)
                {
                    result = stopError;
                }
            }
        }

        const ULONGLONG deadline = GetTickCount64() + 30000;
        while (result == ERROR_SUCCESS && status.dwCurrentState != SERVICE_STOPPED)
        {
            if (GetTickCount64() >= deadline)
            {
                result = ERROR_SERVICE_REQUEST_TIMEOUT;
                break;
            }
            Sleep(200);
            if (!queryStatus(status))
            {
                result = GetLastError();
            }
        }
    }

    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return result;
}

DWORD DeleteSavedState()
{
    const DWORD result = RegDeleteTreeW(HKEY_LOCAL_MACHINE, RegistryPath);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND)
    {
        return ERROR_SUCCESS;
    }
    return result;
}

int DisableGuard(bool removeSavedState)
{
    const DWORD stopResult = StopServiceForRecovery();
    if (stopResult != ERROR_SUCCESS)
    {
        std::wcerr << L"ProxyGauge Guard could not stop its service safely: "
                   << ErrorText(stopResult) << L'\n';
        return static_cast<int>(stopResult);
    }

    const DWORD filterResult = RemoveFilters(true);
    if (filterResult != ERROR_SUCCESS)
    {
        std::wcerr << L"ProxyGauge Guard could not remove WFP filters: "
                   << ErrorText(filterResult) << L'\n';
        return static_cast<int>(filterResult);
    }

    const DWORD stateResult = removeSavedState ? DeleteSavedState() : SaveState(GuardState{});
    if (stateResult != ERROR_SUCCESS)
    {
        std::wcerr << L"ProxyGauge Guard removed WFP filters but could not "
                   << (removeSavedState ? L"delete saved state: " : L"save disabled state: ")
                   << ErrorText(stateResult) << L'\n';
        return static_cast<int>(stateResult);
    }
    std::wcout << (removeSavedState
        ? L"ProxyGauge Guard state and all persistent filters were removed.\n"
        : L"ProxyGauge Guard is disabled and all persistent filters were removed.\n");
    return 0;
}
}

int wmain(int argc, wchar_t** argv)
{
    if (argc == 2 && wcscmp(argv[1], L"--emergency-off") == 0)
    {
        return DisableGuard(false);
    }
    if (argc == 2 && wcscmp(argv[1], L"--uninstall-cleanup") == 0)
    {
        return DisableGuard(true);
    }

    SERVICE_TABLE_ENTRYW serviceTable[] =
    {
        {const_cast<wchar_t*>(ServiceName), ServiceMain},
        {nullptr, nullptr}
    };
    if (!StartServiceCtrlDispatcherW(serviceTable))
    {
        const DWORD error = GetLastError();
        if (error == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT)
        {
            std::wcerr << ServiceDisplayName << L" must be started by Windows Service Control Manager.\n";
        }
        return static_cast<int>(error);
    }
    return 0;
}
