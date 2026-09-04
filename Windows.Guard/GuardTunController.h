#pragma once
#include <windows.h>
#include <roapi.h>
#include <winrt/Windows.Data.Json.h>
#include <functional>
#include <optional>
#include <set>
#include <string>
#include "GuardSelection.h"

namespace GuardTun
{
struct Config { bool enabled = false; std::wstring device; };
struct Controller { std::wstring path; Config tun; };

class Apartment final
{
public:
    Apartment() : result_(RoInitialize(RO_INIT_MULTITHREADED)) {}
    ~Apartment() { if (SUCCEEDED(result_)) RoUninitialize(); }
    bool ready() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }
private:
    HRESULT result_;
};

class Handle final
{
public:
    explicit Handle(HANDLE value) : value_(value) {}
    ~Handle() { if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    HANDLE get() const { return value_; }
private:
    HANDLE value_;
};

inline std::optional<Config> ParseConfig(const std::string& body)
{
    if (body.empty() || body.size() > 65536) return std::nullopt;
    const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, body.data(),
        static_cast<int>(body.size()), nullptr, 0);
    if (length <= 0) return std::nullopt;
    std::wstring text(static_cast<size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, body.data(), static_cast<int>(body.size()),
        text.data(), length) != length) return std::nullopt;
    thread_local Apartment apartment;
    if (!apartment.ready()) return std::nullopt;
    std::optional<Config> result;
    try
    {
        const auto root = winrt::Windows::Data::Json::JsonObject::Parse(text);
        const auto tun = root.GetNamedObject(L"tun");
        const auto enabled = tun.GetNamedBoolean(L"enable");
        const auto device = tun.GetNamedString(L"device", L"");
        if (device.size() <= 256) result = Config{enabled, std::wstring(device)};
    }
    catch (const winrt::hresult_error&) { }
    return result;
}

inline std::optional<Config> ParseResponse(const std::string& response)
{
    if (response.size() > 65536 ||
        (!response.starts_with("HTTP/1.0 200 ") && !response.starts_with("HTTP/1.1 200 ")))
        return std::nullopt;
    const auto end = response.find("\r\n\r\n");
    if (end == std::string::npos || end > 8192) return std::nullopt;
    auto headers = response.substr(0, end);
    std::transform(headers.begin(), headers.end(), headers.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    // HTTP/1.0 requests intentionally use an EOF-delimited body, never chunked encoding.
    if (headers.find("\r\ntransfer-encoding:") != std::string::npos) return std::nullopt;
    const auto body = response.substr(end + 4);
    const auto lengthHeader = headers.find("\r\ncontent-length:");
    if (lengthHeader != std::string::npos)
    {
        auto value = lengthHeader + std::string("\r\ncontent-length:").size();
        while (value < headers.size() && headers[value] == ' ') ++value;
        size_t length = 0, digits = 0;
        while (value < headers.size() && headers[value] >= '0' && headers[value] <= '9')
        {
            length = length * 10 + static_cast<size_t>(headers[value++] - '0');
            if (++digits > 5 || length > 65536) return std::nullopt;
        }
        if (digits == 0 || (value != headers.size() && headers.compare(value, 2, "\r\n") != 0) ||
            length != body.size() || headers.find("\r\ncontent-length:", value) != std::string::npos)
            return std::nullopt;
    }
    return ParseConfig(body);
}

inline bool Transfer(HANDLE pipe, bool write, void* bytes, DWORD capacity, DWORD& count,
    ULONGLONG deadline, DWORD& error)
{
    Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (event.get() == nullptr) { error = GetLastError(); return false; }
    OVERLAPPED operation{};
    operation.hEvent = event.get();
    const BOOL done = write ? WriteFile(pipe, bytes, capacity, &count, &operation)
        : ReadFile(pipe, bytes, capacity, &count, &operation);
    if (done) return true;
    error = GetLastError();
    if (error != ERROR_IO_PENDING) return false;
    const auto now = GetTickCount64();
    const DWORD remaining = now < deadline ? static_cast<DWORD>(deadline - now) : 0;
    if (WaitForSingleObject(operation.hEvent, remaining) != WAIT_OBJECT_0)
    {
        CancelIoEx(pipe, &operation);
        GetOverlappedResult(pipe, &operation, &count, TRUE);
        error = ERROR_TIMEOUT;
        return false;
    }
    if (GetOverlappedResult(pipe, &operation, &count, FALSE)) return true;
    error = GetLastError();
    return false;
}

inline std::optional<Controller> Read(const wchar_t* pipeName,
    const std::set<std::wstring>& running,
    const std::function<std::optional<std::wstring>(DWORD)>& processPath)
{
    const auto deadline = GetTickCount64() + 350;
    // The untrusted endpoint cannot impersonate the LocalSystem client. Never read credentials.
    Handle pipe(CreateFileW(pipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_ANONYMOUS, nullptr));
    if (pipe.get() == INVALID_HANDLE_VALUE) return std::nullopt;
    ULONG server = 0;
    if (!GetNamedPipeServerProcessId(pipe.get(), &server)) return std::nullopt;
    const auto path = processPath(server);
    if (!path.has_value() || !running.contains(ProxySelection::Lower(*path)) ||
        !ProxySelection::IsClashCore(*path)) return std::nullopt;
    std::string request = "GET /configs HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    DWORD written = 0, error = 0;
    if (!Transfer(pipe.get(), true, request.data(), static_cast<DWORD>(request.size()), written, deadline, error) ||
        written != request.size()) return std::nullopt;
    std::string response;
    for (;;)
    {
        char buffer[4096];
        DWORD count = 0;
        if (!Transfer(pipe.get(), false, buffer, sizeof(buffer), count, deadline, error))
        {
            if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED || error == ERROR_NO_DATA) break;
            return std::nullopt;
        }
        if (count == 0) break;
        if (response.size() + count > 65536) return std::nullopt;
        response.append(buffer, count);
    }
    const auto tun = ParseResponse(response);
    return tun.has_value() ? std::optional<Controller>({ProxySelection::Lower(*path), *tun}) : std::nullopt;
}
}
