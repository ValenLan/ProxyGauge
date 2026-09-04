using ProxyGauge.Models;

namespace ProxyGauge.Services;

public static class GuardProtocol
{
    public static IReadOnlyList<ProxyApplicationChoice> ParseApplications(string response)
    {
        RequireSuccess(response, "APPLICATIONS");
        try
        {
            return response.TrimEnd('\0', '\r', '\n').Split('\t').Skip(2)
                .Select(ProxyApplicationSelection.NormalizePath)
                .Where(path => path.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Select(path => new ProxyApplicationChoice($"{System.IO.Path.GetFileNameWithoutExtension(path)} — {path}", path))
                .ToArray();
        }
        catch (System.IO.InvalidDataException) { throw new GuardCommandException("INVALID_RESPONSE"); }
    }

    public static string CreateApplicationEnableRequest(string? executablePath)
    {
        var path = ProxyApplicationSelection.NormalizePath(executablePath);
        return "ENABLE_APP\t" + (path.Length == 0 ? "CLASH" : path);
    }

    public static GuardStatus ParseStatus(string response)
    {
        var fields = response.TrimEnd('\0', '\r', '\n').Split('\t');
        if (fields.Length < 6 || fields[0] != "OK" || fields[1] != "STATUS" ||
            !int.TryParse(fields[4], out var filterCount) || filterCount < 0)
        {
            throw new GuardCommandException("INVALID_RESPONSE");
        }

        var owned = fields[5] == "OWNED";
        var status = fields[2] switch
        {
            "DISABLED" => new GuardStatus(GuardStatusKind.Disabled, owned, filterCount),
            "ENABLED" when fields[3] == "HEALTHY" =>
                new GuardStatus(GuardStatusKind.Enabled, owned, filterCount),
            "ENABLED" => new GuardStatus(GuardStatusKind.Fault, owned, filterCount, "FILTER_FAULT"),
            _ => throw new GuardCommandException("INVALID_RESPONSE")
        };
        if (fields.Length == 6) return status; // Older services remain readable, but cannot silently emulate auto-follow.
        if (fields.Length != 9 || fields[6] is not ("AUTO" or "PINNED") || fields[8] is not ("CHOOSE" or "READY"))
            throw new GuardCommandException("INVALID_RESPONSE");
        try
        {
            return status with { AutomaticSelection = fields[6] == "AUTO",
                ProxyExecutablePath = ProxyApplicationSelection.NormalizePath(fields[7]), SelectionRequired = fields[8] == "CHOOSE" };
        }
        catch (System.IO.InvalidDataException) { throw new GuardCommandException("INVALID_RESPONSE"); }
    }

    public static void RequireSuccess(string response, string operation)
    {
        var fields = response.TrimEnd('\0', '\r', '\n').Split('\t');
        if (fields.Length >= 2 && fields[0] == "OK" && fields[1] == operation)
        {
            return;
        }
        if (fields.Length >= 2 && fields[0] == "ERROR")
        {
            throw new GuardCommandException(fields[1]);
        }
        throw new GuardCommandException("INVALID_RESPONSE");
    }
}

public sealed class GuardCommandException : Exception
{
    public GuardCommandException(string code) : base(MessageFor(code))
    {
        Code = code;
    }

    public string Code { get; }

    private static string MessageFor(string code) => code switch
    {
        "PROXY_NOT_LISTENING" => "本地代理核心尚未监听当前 mixed 端口，保护没有开启。",
        "PROXY_NOT_RUNNING" => "尚未找到运行中的代理核心。请启动代理客户端后重试；断网保护不需要填写端口。",
        "PROXY_AMBIGUOUS" => "检测到多个运行中的代理核心，需要选择本次信任的应用；不需要填写端口。",
        "INVALID_PROXY_PATH" => "代理核心路径无效，请选择本机磁盘上的 .exe 文件。",
        "BAD_REQUEST" => "保护服务不支持当前请求，请确保界面与 Guard 服务使用同一版本。",
        "OWNER_MISMATCH" => "保护由另一个 Windows 用户开启，请切换到该用户或使用管理员恢复命令。",
        "INVALID_PORT" => "mixed 端口无效，保护没有开启。",
        "WFP_ENABLE_FAILED" => "Windows Filtering Platform 无法建立保护规则。",
        "WFP_DISABLE_FAILED" => "Windows Filtering Platform 无法完整移除保护规则。",
        "STATE_SAVE_FAILED" => "系统保护状态无法安全保存，请先使用管理员恢复命令。",
        "IDENTITY_FAILED" => "系统服务无法确认当前 Windows 用户。",
        "SERVICE_UNAVAILABLE" => "ProxyGauge Guard Service 未安装、未启动或没有响应。",
        "FILTER_FAULT" => "保护规则未通过完整性确认，请勿假设公网直连已被阻断。",
        _ => "系统保护服务返回了无法识别的结果。"
    };
}
