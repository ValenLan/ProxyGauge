#pragma once
#include <algorithm>
#include <cwctype>
#include <optional>
#include <set>
#include <string>

namespace ProxySelection
{
inline std::wstring Lower(std::wstring value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return value;
}

inline bool IsKnownCore(const std::wstring& path)
{
    const auto name = Lower(path.substr(path.find_last_of(L"\\/") + 1));
    const std::set<std::wstring> names = {L"clash.exe", L"clash-meta.exe", L"mihomo.exe", L"verge-mihomo.exe",
        L"ikuuuvpncore.exe", L"sing-box.exe", L"singbox.exe", L"xray.exe", L"v2ray.exe"};
    return names.contains(name);
}

inline bool IsClashCore(const std::wstring& path)
{
    const auto name = Lower(path.substr(path.find_last_of(L"\\/") + 1));
    return name == L"clash.exe" || name == L"clash-meta.exe" || name == L"mihomo.exe" || name == L"verge-mihomo.exe";
}

struct Choice { std::wstring path; bool ambiguous = false; bool running = false; };

inline Choice Select(const std::set<std::wstring>& running, const std::optional<std::wstring>& systemProxy,
    const std::wstring& previous, const std::set<std::wstring>& activeTunnelCores = {})
{
    // An enabled OS proxy with a verified known-core listener is the strongest current-path evidence.
    if (systemProxy.has_value() && running.contains(Lower(*systemProxy))) return {Lower(*systemProxy), false, true};
    std::set<std::wstring> active;
    for (const auto& core : activeTunnelCores)
        if (running.contains(Lower(core))) active.insert(Lower(core));
    if (active.size() == 1) return {*active.begin(), false, true};
    if (active.size() > 1) return {previous, true, running.contains(Lower(previous))};
    if (running.size() == 1) return {*running.begin(), false, true};
    if (running.contains(Lower(previous))) return {Lower(previous), running.size() > 1, true};
    return {previous, running.size() > 1, false}; // Keep the old block/permit transaction until a safe choice exists.
}

inline std::optional<unsigned short> LoopbackProxyPort(std::wstring endpoint)
{
    endpoint = Lower(endpoint);
    const auto colon = endpoint.find_last_of(L':');
    if (colon == std::wstring::npos) return std::nullopt;
    const auto host = endpoint.substr(0, colon);
    if (host != L"127.0.0.1" && host != L"localhost" && host != L"[::1]") return std::nullopt;
    const auto text = endpoint.substr(colon + 1);
    if (text.empty() || text.size() > 5 || !std::all_of(text.begin(), text.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; }))
        return std::nullopt;
    const auto value = std::stoul(text);
    return value > 0 && value <= 65535 ? std::optional<unsigned short>(static_cast<unsigned short>(value)) : std::nullopt;
}
}
