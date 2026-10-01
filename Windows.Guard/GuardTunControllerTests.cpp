#include <winsock2.h>
#include "GuardTunController.h"
#include <iostream>
#include <stdexcept>
#include <thread>

int main()
{
    int assertion = 0;
    const auto check = [&](bool value)
    {
        ++assertion;
        if (!value) throw std::runtime_error("TUN controller assertion " + std::to_string(assertion) + " failed");
        std::cout << "TUN assertion " << assertion << " passed." << std::endl;
    };
    const std::string body = R"({"tun":{"enable":true,"device":"Mihomo"}})";
    const auto config = GuardTun::ParseConfig(body);
    check(config.has_value() && config->enabled && config->device == L"Mihomo");
    check(!GuardTun::ParseConfig(R"({"tun":{"enable":"true","device":"Mihomo"}})").has_value());
    check(!GuardTun::ParseConfig(R"({"other":{"enable":true,"device":"Mihomo"}})").has_value());
    check(!GuardTun::ParseConfig("{\xff}").has_value());
    check(!GuardTun::ParseConfig(std::string(65537, 'x')).has_value());
    check(!GuardTun::ParseConfig(R"({"tun":{"enable":false}})")->enabled);
    const auto response = "HTTP/1.0 200 OK\r\nContent-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
    check(GuardTun::ParseResponse(response).has_value());
    check(!GuardTun::ParseResponse("HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\n" + body).has_value());
    check(!GuardTun::ParseResponse("HTTP/1.0 403 Forbidden\r\n\r\n" + body).has_value());
    check(!GuardTun::ParseResponse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + body).has_value());

    const std::wstring path = L"c:\\proxy\\verge-mihomo.exe";
    const std::wstring inactiveKnownPath = L"c:\\other-proxy\\mihomo.exe";
    const std::wstring unknownPath = L"c:\\browser.exe";
    for (int scenario = 0; scenario < 6; ++scenario)
    {
        const auto name = L"\\\\.\\pipe\\ProxyGauge.Guard.TunTest." + std::to_wstring(GetCurrentProcessId()) + L"." + std::to_wstring(scenario);
        GuardTun::Handle server(CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_WAIT,
            1, 8192, 8192, 0, nullptr));
        check(server.get() != INVALID_HANDLE_VALUE);
        bool receivedRequest = false;
        std::thread responder([&]
        {
            if (!ConnectNamedPipe(server.get(), nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) return;
            char buffer[1024]; DWORD count = 0;
            if (!ReadFile(server.get(), buffer, sizeof(buffer), &count, nullptr)) return;
            receivedRequest = std::string(buffer, count).starts_with("GET /configs HTTP/1.0\r\n");
            if (scenario == 2) { Sleep(600); DisconnectNamedPipe(server.get()); return; }
            WriteFile(server.get(), response.data(), static_cast<DWORD>(response.size()), &count, nullptr);
            FlushFileBuffers(server.get());
            DisconnectNamedPipe(server.get());
        });
        bool identityVerified = false;
        const std::set<std::wstring> running = scenario == 4
            ? std::set<std::wstring>{unknownPath} : std::set<std::wstring>{path};
        // Each negative case isolates one identity gate. The original browser
        // case fails both known-core and running-membership checks at once.
        if (scenario == 3) check(ProxySelection::IsClashCore(inactiveKnownPath) && !running.contains(inactiveKnownPath));
        if (scenario == 4) check(!ProxySelection::IsClashCore(unknownPath) && running.contains(unknownPath));
        const auto started = GetTickCount64();
        const auto result = GuardTun::Read(name.c_str(), running, [&](DWORD processId) -> std::optional<std::wstring>
        {
            identityVerified = processId == GetCurrentProcessId();
            if (scenario == 5) return std::nullopt; // The server process identity could not be read.
            if (scenario == 3) return inactiveKnownPath; // A known core is absent from the current running snapshot.
            return scenario == 1 || scenario == 4 ? unknownPath : path;
        });
        const auto elapsed = GetTickCount64() - started;
        responder.join();
        std::cout << "Pipe scenario " << scenario << ": response=" << result.has_value()
            << ", request=" << receivedRequest << ", milliseconds=" << elapsed << std::endl;
        check(identityVerified);
        if (scenario == 0) check(result.has_value() && result->path == path && result->tun.enabled && receivedRequest);
        if (scenario == 1 || scenario >= 3) check(!result.has_value() && !receivedRequest);
        if (scenario == 2) check(!result.has_value() && elapsed < 600);
    }
    std::cout << "TUN controller parsing, process identity and bounded pipe tests passed.\n";
}
