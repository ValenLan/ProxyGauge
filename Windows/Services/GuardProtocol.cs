using ProxyGauge.Models;

namespace ProxyGauge.Services;

public static class GuardProtocol
{
    public static GuardStatus ParseStatus(string response)
    {
        var fields = response.TrimEnd('\0', '\r', '\n').Split('\t');
        if (fields.Length < 6 || fields[0] != "OK" || fields[1] != "STATUS" ||
            !int.TryParse(fields[4], out var filterCount) || filterCount < 0)
        {
            throw new GuardCommandException("INVALID_RESPONSE");
        }

        var owned = fields[5] == "OWNED";
        return fields[2] switch
        {
            "DISABLED" => new GuardStatus(GuardStatusKind.Disabled, owned, filterCount),
            "ENABLED" when fields[3] == "HEALTHY" =>
                new GuardStatus(GuardStatusKind.Enabled, owned, filterCount),
            "ENABLED" => new GuardStatus(GuardStatusKind.Fault, owned, filterCount, "FILTER_FAULT"),
            _ => throw new GuardCommandException("INVALID_RESPONSE")
        };
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
        "OWNER_MISMATCH" => "保护由另一个 Windows 用户开启，请切换到该用户或使用管理员恢复命令。",
        "INVALID_PORT" => "mixed 端口无效，保护没有开启。",
        "WFP_ENABLE_FAILED" => "Windows Filtering Platform 无法建立保护规则。",
        "WFP_DISABLE_FAILED" => "Windows Filtering Platform 无法完整移除保护规则。",
        "STATE_SAVE_FAILED" => "系统保护状态无法安全保存，请先使用管理员恢复命令。",
        "IDENTITY_FAILED" => "系统服务无法确认当前 Windows 用户。",
        "SERVICE_UNAVAILABLE" => "ProxyGauge Guard Service 未安装、未启动或没有响应。",
        _ => "系统保护服务返回了无法识别的结果。"
    };
}
