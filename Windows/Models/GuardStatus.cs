namespace ProxyGauge.Models;

public enum GuardStatusKind
{
    Unavailable,
    Disabled,
    Enabled,
    Fault
}

public sealed record GuardStatus(
    GuardStatusKind Kind,
    bool OwnedByCurrentUser,
    int FilterCount,
    string ErrorCode = "")
{
    public bool IsEnabled => Kind is GuardStatusKind.Enabled or GuardStatusKind.Fault;
    public bool IsHealthy => Kind == GuardStatusKind.Enabled;

    public static GuardStatus Unavailable(string errorCode = "SERVICE_UNAVAILABLE") =>
        new(GuardStatusKind.Unavailable, true, 0, errorCode);
}
