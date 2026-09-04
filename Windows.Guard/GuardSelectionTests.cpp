#include "GuardSelection.h"
#include <iostream>
#include <stdexcept>

int main()
{
    const std::wstring a = L"c:\\proxy-a\\mihomo.exe", b = L"c:\\proxy-b\\ikuuuvpncore.exe";
    const auto check = [](bool ok) { if (!ok) throw std::runtime_error("Guard selection assertion failed"); };
    check(ProxySelection::IsKnownCore(a) && ProxySelection::IsKnownCore(L"C:\\Proxy\\iKuuuVPNCore.EXE"));
    check(!ProxySelection::IsKnownCore(L"clash-verge-service.exe") && !ProxySelection::IsKnownCore(L"iKuuuVPN.exe"));
    check(!ProxySelection::IsKnownCore(L"unrelatedcore.exe"));
    check(ProxySelection::Select({b}, std::nullopt, a).path == b); // automatic handover after old core exits
    auto chosen = ProxySelection::Select({a,b}, b, a);
    check(chosen.path == b && chosen.running && !chosen.ambiguous); // old core still running, new OS entry
    chosen = ProxySelection::Select({a,b}, L"c:\\browser.exe", a);
    check(chosen.path == a && chosen.ambiguous); // unrelated port owner cannot gain a permit
    chosen = ProxySelection::Select({}, std::nullopt, a);
    check(chosen.path == a && !chosen.running); // retain persistent block while disconnected
    chosen = ProxySelection::Select({a,b}, std::nullopt, L"");
    check(chosen.path.empty() && chosen.ambiguous && !chosen.running);
    chosen = ProxySelection::Select({a,b}, std::nullopt, b, {a});
    check(chosen.path == a && chosen.running && !chosen.ambiguous); // Clash TUN replaces a dormant VPN core
    chosen = ProxySelection::Select({a,b}, std::nullopt, a, {b});
    check(chosen.path == b && !chosen.ambiguous); // the VPN TUN can become active again
    chosen = ProxySelection::Select({a,b}, std::nullopt, a, {a,b});
    check(chosen.path == a && chosen.ambiguous); // conflicting active tunnels never grant both cores
    chosen = ProxySelection::Select({a,b}, b, a, {a});
    check(chosen.path == b && !chosen.ambiguous); // an explicit verified HTTPS proxy still wins
    chosen = ProxySelection::Select({a,b}, std::nullopt, b, {L"c:\\unrelated.exe"});
    check(chosen.path == b && chosen.ambiguous); // unverified and stopped identities cannot get a permit
    check(ProxySelection::LoopbackProxyPort(L"127.0.0.1:7890") == 7890);
    check(ProxySelection::LoopbackProxyPort(L"[::1]:7897") == 7897);
    check(!ProxySelection::LoopbackProxyPort(L"192.168.0.1:7890").has_value());
    check(!ProxySelection::LoopbackProxyPort(L"127.0.0.1:7890junk").has_value());
    check(!ProxySelection::LoopbackProxyPort(L"127.0.0.1:65536").has_value());
    std::cout << "Guard automatic handover policy tests passed.\n";
}
