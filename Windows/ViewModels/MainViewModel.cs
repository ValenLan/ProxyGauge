using System.IO;
using System.Windows.Media;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge.ViewModels;

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly ConfigService _configService;
    private readonly GuardActivationService _guardActivation;
    private readonly Func<CancellationToken, Task> _disableGuard;
    private readonly Func<AppConfig, CancellationToken, Task<ProxySnapshot>> _probeAsync;
    private readonly Func<AppConfig, CancellationToken, Task<ExitSummary>> _exitResolver;
    private readonly Func<CancellationToken, Task<GuardStatus>> _guardStatusResolver;
    private readonly Func<AppConfig, CancellationToken, Task<HealthReport>> _healthCheckAsync;
    private readonly ExitSummaryStore _exitSummaryStore;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private AppConfig _config;
    private string _headline = "正在读取代理状态";
    private string _detail = "稍等片刻，ProxyGauge 正在检查本地流量入口";
    private HealthLevel _overallLevel = HealthLevel.Idle;
    private bool _isBusy;
    private bool _isHealthCheckRunning;
    private string _healthButtonLabel = "检测";
    private string _lastUpdated = "尚未刷新";
    private GuardStatus _guardStatus = GuardStatus.Unavailable();
    private bool _isGuardBusy;
    private long _guardRevision;
    private string? _activeGuardApplication;
    private ExitSummary _exitSummary = ExitSummary.Unavailable();
    private CancellationTokenSource? _activeRefreshCancellation;
    private CancellationTokenSource? _activeExitRefreshCancellation;
    private CancellationTokenSource? _exitSettlementCancellation;
    private readonly TimeSpan _exitSettlementTimeout;
    private bool _exitSettlementExpired;
    private Task _refreshLoopTask = Task.CompletedTask;
    private long _refreshGeneration;
    private long _exitRefreshGeneration;
    private bool _refreshRequested;
    private string? _observedExitPathFingerprint;
    private bool _disposed;
    private bool _connectionHasSystemProxy;
    private bool _connectionHasVirtualAdapter;
    private string? _detectedClientName;
    private bool _proxyStatusAvailable;

    public MainViewModel(
        ConfigService configService,
        ProxyProbeService probeService,
        HealthCheckService healthCheckService,
        GuardClient guardClient)
        : this(
            configService,
            healthCheckService,
            guardClient,
            probeService.ProbeAsync,
            ExitSummaryService.ResolveAsync,
            guardClient.GetStatusAsync,
            healthCheckService.RunAsync)
    {
    }

    internal MainViewModel(
        ConfigService configService,
        HealthCheckService healthCheckService,
        GuardClient guardClient,
        Func<AppConfig, CancellationToken, Task<ProxySnapshot>> probeAsync,
        Func<AppConfig, CancellationToken, Task<ExitSummary>> exitResolver,
        Func<CancellationToken, Task<GuardStatus>> guardStatusResolver,
        Func<AppConfig, CancellationToken, Task<HealthReport>>? healthCheckAsync = null,
        GuardActivationService? guardActivation = null,
        Func<CancellationToken, Task>? disableGuard = null,
        TimeSpan? exitSettlementTimeout = null,
        ExitSummaryStore? exitSummaryStore = null)
    {
        _configService = configService;
        _guardActivation = guardActivation ?? new GuardActivationService(guardClient);
        _disableGuard = disableGuard ?? guardClient.DisableAsync;
        _exitSettlementTimeout = exitSettlementTimeout ?? TimeSpan.FromSeconds(16);
        _probeAsync = probeAsync;
        _exitResolver = exitResolver;
        _guardStatusResolver = guardStatusResolver;
        _healthCheckAsync = healthCheckAsync ?? healthCheckService.RunAsync;
        _config = _configService.Load();
        _exitSummaryStore = exitSummaryStore ?? new ExitSummaryStore(_configService.ConfigPath);
        var persistedExit = _exitSummaryStore.Load();
        _observedExitPathFingerprint = persistedExit.PathFingerprint;
        _exitSummary = persistedExit.Summary ?? ExitSummary.WaitingForPathChange();

        Core = new MetricViewModel(new MetricSnapshot("代理核心", "检查中", "正在查找 Mihomo", "核", HealthLevel.Idle));
        Port = new MetricViewModel(new MetricSnapshot(
            "本地端口",
            "检查中",
            LocalEndpointPolicy.FormatEndpoint(_config.MixedHost, _config.MixedPort),
            "端",
            HealthLevel.Idle));
        Route = new MetricViewModel(new MetricSnapshot("流量入口", "检查中", "系统代理或 TUN", "入", HealthLevel.Idle));
    }

    public MetricViewModel Core { get; }
    public MetricViewModel Port { get; }
    public MetricViewModel Route { get; }
    public string Headline { get => _headline; private set => SetProperty(ref _headline, value); }
    public string Detail { get => _detail; private set => SetProperty(ref _detail, value); }
    public string HealthButtonLabel { get => _healthButtonLabel; private set => SetProperty(ref _healthButtonLabel, value); }
    public string LastUpdated { get => _lastUpdated; private set => SetProperty(ref _lastUpdated, value); }
    public string Endpoint => LocalEndpointPolicy.FormatEndpoint(_config.MixedHost, _config.MixedPort);
    public string ConnectionValue => BuildConnectionStatus(
        _connectionHasSystemProxy,
        _connectionHasVirtualAdapter,
        _exitSummary.State == ExitSummaryState.Disconnected,
        _proxyStatusAvailable,
        OverallLevel,
        Headline).Value;
    public HealthLevel ConnectionLevel => BuildConnectionStatus(
        _connectionHasSystemProxy,
        _connectionHasVirtualAdapter,
        _exitSummary.State == ExitSummaryState.Disconnected,
        _proxyStatusAvailable,
        OverallLevel,
        Headline).Level;
    public Brush ConnectionBrush => Palette.ForLevel(ConnectionLevel);
    public string ConnectionDetail => BuildConnectionClientDetail(
        _activeGuardApplication,
        _detectedClientName,
        _connectionHasSystemProxy,
        _connectionHasVirtualAdapter,
        _exitSummary.State == ExitSummaryState.Disconnected,
        _proxyStatusAvailable);

    internal static (string Value, HealthLevel Level) BuildConnectionStatus(
        bool hasSystemProxy,
        bool hasVirtualAdapter,
        bool networkDisconnected,
        bool probeAvailable,
        HealthLevel fallbackLevel,
        string fallbackHeadline)
    {
        if (networkDisconnected) return ("无网络连接", HealthLevel.Error);
        if (hasSystemProxy && hasVirtualAdapter)
            return ("系统代理 + 虚拟网卡", HealthLevel.Warning);
        if (hasVirtualAdapter) return ("虚拟网卡", HealthLevel.Ok);
        if (hasSystemProxy) return ("系统代理", HealthLevel.Ok);
        if (probeAvailable) return ("未检测到代理", HealthLevel.Idle);
        return fallbackLevel switch
        {
            HealthLevel.Ok => ("代理路径", HealthLevel.Ok),
            HealthLevel.Warning => (fallbackHeadline, HealthLevel.Warning),
            HealthLevel.Error => ("代理状态不可用", HealthLevel.Error),
            _ => ("检查中", HealthLevel.Idle)
        };
    }

    internal static string BuildConnectionClientDetail(
        string? selectedApplication,
        string? detectedClientName,
        bool hasSystemProxy,
        bool hasVirtualAdapter,
        bool networkDisconnected,
        bool probeAvailable)
    {
        if (networkDisconnected) return "请检查网络连接";
        if (!hasSystemProxy && !hasVirtualAdapter)
            return probeAvailable ? "当前使用直连网络" : "代理状态暂时不可用";
        var selectedCore = string.IsNullOrWhiteSpace(selectedApplication)
            ? null
            : Path.GetFileNameWithoutExtension(selectedApplication);
        var selectedName = selectedCore is null
            ? null
            : ProxyProbeService.DetectClientName([selectedCore]);
        var client = selectedName ?? detectedClientName;
        if (!string.IsNullOrWhiteSpace(client) && !string.IsNullOrWhiteSpace(selectedCore) &&
            !client.Equals(selectedCore, StringComparison.OrdinalIgnoreCase))
            return $"{client} · {selectedCore}";
        if (!string.IsNullOrWhiteSpace(selectedCore)) return selectedCore;
        if (!string.IsNullOrWhiteSpace(client)) return client;
        if (hasSystemProxy && hasVirtualAdapter) return "其他 VPN / 代理已连接";
        if (hasVirtualAdapter) return "其他 VPN 已连接";
        if (hasSystemProxy) return "其他系统代理已启用";
        return "未检测到代理客户端";
    }

    internal static bool HasDetectedSystemPath(ProxySnapshot snapshot) =>
        snapshot.SystemProxyEnabled ||
        snapshot.TunDetected ||
        snapshot.OtherTunnelDetected;
    public string ExitAddress => _exitSummary.Address;
    public string ExitLocation => _exitSummary.Location;
    public string ExitIpVersion => _exitSummary.IpVersion ?? string.Empty;
    public bool HasExitIpVersion => _exitSummary.HasIpVersion;
    public string PlanSummary => _config.SecondaryEnabled
        ? $"基础链路 · 出口一致 · {_config.SecondaryLabel} 分流"
        : "代理核心 · 流量入口 · 出口一致";
    public string HealthDetail => IsHealthCheckRunning ? "正在按方案检测…" : "按当前方案检查连接";
    public Brush GuardLevelBrush => _guardStatus.Kind switch
    {
        GuardStatusKind.Enabled when _guardStatus.SelectionRequired => Palette.Warning,
        GuardStatusKind.Enabled => Palette.Success,
        GuardStatusKind.Fault => Palette.Error,
        _ => Palette.Idle
    };
    public string GuardValue => _guardStatus.Kind switch
    {
        GuardStatusKind.Enabled => "已开启",
        GuardStatusKind.Fault => "需要修复",
        GuardStatusKind.Disabled => "已关闭",
        _ => "服务未安装"
    };
    public string GuardDetail => _guardStatus.Kind switch
    {
        GuardStatusKind.Enabled when !_guardStatus.OwnedByCurrentUser =>
            "由其他 Windows 用户开启，退出界面后仍然生效",
        GuardStatusKind.Enabled when _guardStatus.SelectionRequired =>
            "多个代理核心仍在运行，当前入口无法确定。保护继续生效；请点击选择当前使用的代理。",
        GuardStatusKind.Enabled => (_activeGuardApplication is null ? "" : $"已识别 {Path.GetFileNameWithoutExtension(_activeGuardApplication)}；") +
            "持续拦截当前用户的公网直连，保留局域网；信任选中核心的 DIRECT，不覆盖系统服务和其他用户",
        GuardStatusKind.Fault => "持久规则不完整，请勿假设真实 IP 已受保护",
        GuardStatusKind.Disabled => "只有明确开启后才会拦截；关闭界面不改变状态",
        _ => "请使用 ProxyGauge MSI 安装系统保护服务"
    };
    public string GuardButtonLabel => _isGuardBusy
        ? "处理中…"
        : _guardStatus.Kind switch
        {
            GuardStatusKind.Enabled or GuardStatusKind.Fault => "关闭",
            _ => "开启"
        };
    public bool GuardEnabled => _guardStatus.IsEnabled;
    public string GuardApplicationLabel => _guardStatus.SelectionRequired
        ? "选择当前代理"
        : string.Empty;
    public bool ShowGuardApplicationAction => GuardEnabled && _guardStatus.SelectionRequired;
    public string GuardPathFingerprint => $"{_guardStatus.Kind}|{_guardStatus.ProxyExecutablePath}|{_guardStatus.SelectionRequired}";
    public bool CanChangeGuard => !_disposed && !_isGuardBusy &&
        (_guardStatus.Kind == GuardStatusKind.Unavailable || _guardStatus.OwnedByCurrentUser);

    public HealthLevel OverallLevel
    {
        get => _overallLevel;
        private set
        {
            if (SetProperty(ref _overallLevel, value))
            {
                OnPropertyChanged(nameof(OverallBrush));
                OnPropertyChanged(nameof(OverallBackground));
                OnPropertyChanged(nameof(OverallMark));
                OnPropertyChanged(nameof(ConnectionValue));
                OnPropertyChanged(nameof(ConnectionLevel));
                OnPropertyChanged(nameof(ConnectionBrush));
            }
        }
    }

    public Brush OverallBrush => Palette.ForLevel(OverallLevel);
    public Brush OverallBackground => Palette.BackgroundForLevel(OverallLevel);
    public string OverallMark => OverallLevel switch
    {
        HealthLevel.Ok => "✓",
        HealthLevel.Warning => "!",
        HealthLevel.Error => "×",
        _ => "·"
    };

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetProperty(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(IsNotBusy));
                OnPropertyChanged(nameof(CanChangeGuard));
            }
        }
    }

    public bool IsNotBusy => !IsBusy && !IsGuardBusy;
    public bool IsGuardBusy
    {
        get => _isGuardBusy;
        private set
        {
            if (SetProperty(ref _isGuardBusy, value))
            {
                OnPropertyChanged(nameof(GuardButtonLabel));
                OnPropertyChanged(nameof(CanChangeGuard));
                OnPropertyChanged(nameof(IsNotBusy));
            }
        }
    }
    public bool IsHealthCheckRunning
    {
        get => _isHealthCheckRunning;
        private set
        {
            if (SetProperty(ref _isHealthCheckRunning, value))
            {
                OnPropertyChanged(nameof(HealthDetail));
            }
        }
    }

    public Task RefreshAsync()
    {
        if (_disposed)
        {
            return Task.CompletedTask;
        }

        _refreshRequested = true;
        _refreshGeneration++;
        _activeRefreshCancellation?.Cancel();
        return StartRefreshLoopIfNeeded();
    }

    public bool ObserveExitPathFingerprint(string fingerprint)
    {
        if (_disposed || fingerprint.Length != 64 || !fingerprint.All(character =>
                character is >= '0' and <= '9' or >= 'A' and <= 'F' or >= 'a' and <= 'f'))
            return false;
        if (_observedExitPathFingerprint is null)
        {
            _observedExitPathFingerprint = fingerprint;
            _exitSummaryStore.RecordPathFingerprint(fingerprint, clearSummary: false);
            return false;
        }
        if (string.Equals(_observedExitPathFingerprint, fingerprint, StringComparison.OrdinalIgnoreCase))
            return false;

        _observedExitPathFingerprint = fingerprint;
        _exitSummaryStore.RecordPathFingerprint(fingerprint, clearSummary: true);
        InvalidateExitSummary(clearPersistedSummary: false);
        return true;
    }

    public async Task RefreshExitAsync()
    {
        if (_disposed) return;
        var generation = ++_exitRefreshGeneration;
        if (!_exitSettlementExpired && _exitSummary.State != ExitSummaryState.Disconnected)
            ApplyExit(ExitSummary.Checking());
        if (_exitSettlementCancellation is null)
        {
            _exitSettlementCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetimeCancellation.Token);
            _ = SettleExitDeadlineAsync(_exitSettlementCancellation.Token);
        }

        _activeExitRefreshCancellation?.Cancel();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetimeCancellation.Token);
        _activeExitRefreshCancellation = cancellation;
        ExitSummary summary;
        try
        {
            summary = await InvokeSafely(() => _exitResolver(_config.Clone(), cancellation.Token));
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return;
        }
        catch
        {
            summary = ExitSummary.Unavailable();
        }
        finally
        {
            if (ReferenceEquals(_activeExitRefreshCancellation, cancellation))
                _activeExitRefreshCancellation = null;
        }

        if (_disposed || cancellation.IsCancellationRequested || generation != _exitRefreshGeneration)
            return;
        _exitSettlementCancellation?.Cancel();
        _exitSettlementCancellation?.Dispose();
        _exitSettlementCancellation = null;
        _exitSettlementExpired = false;
        ApplyExit(summary);
        if (summary.State == ExitSummaryState.Available && ExitSummary.IsSupportedAddress(summary.Address))
            _exitSummaryStore.SaveSummary(summary);
    }

    private Task StartRefreshLoopIfNeeded()
    {
        if (!_disposed && !IsHealthCheckRunning && !IsGuardBusy &&
            _refreshRequested && _refreshLoopTask.IsCompleted)
        {
            _refreshLoopTask = RunRefreshLoopAsync();
        }
        return _refreshLoopTask;
    }

    public void InvalidateExitSummary(bool clearPersistedSummary = true)
    {
        if (_disposed)
        {
            return;
        }

        _exitRefreshGeneration++;
        // No query is running during debounce or while the window is inactive.
        if (_exitSummary.State != ExitSummaryState.Disconnected)
            ApplyExit(_exitSettlementExpired ? ExitSummary.Unavailable() : ExitSummary.Waiting());
        _activeExitRefreshCancellation?.Cancel();
        if (clearPersistedSummary) _exitSummaryStore.ClearSummary();
    }

    public void NotifyNetworkUnavailable()
    {
        if (_disposed) return;
        _exitRefreshGeneration++;
        _activeExitRefreshCancellation?.Cancel();
        ApplyExit(ExitSummary.Disconnected());
    }

    private async Task SettleExitDeadlineAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(_exitSettlementTimeout, token);
            if (_disposed) return;
            _exitSettlementExpired = true;
            if (_exitSummary.State is ExitSummaryState.Checking or ExitSummaryState.Unavailable)
                ApplyExit(ExitSummary.Unavailable());
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    private async Task RunRefreshLoopAsync()
    {
        IsBusy = true;
        try
        {
            while (_refreshRequested && !_disposed)
            {
                _refreshRequested = false;
                var generation = _refreshGeneration;
                var config = _config.Clone();
                using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
                    _lifetimeCancellation.Token);
                _activeRefreshCancellation = cancellation;
                try
                {
                    await RunSingleRefreshAsync(config, generation, cancellation.Token);
                }
                finally
                {
                    if (ReferenceEquals(_activeRefreshCancellation, cancellation))
                    {
                        _activeRefreshCancellation = null;
                    }
                }
            }
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task RunSingleRefreshAsync(
        AppConfig config,
        long generation,
        CancellationToken cancellationToken)
    {
        // Publish local Guard status without waiting for public-IP or proxy probes.
        var guardTask = RefreshGuardStatusAsync(cancellationToken);
        var probeTask = InvokeSafely(() => _probeAsync(config, cancellationToken));

        ProxySnapshot? snapshot = null;
        try
        {
            snapshot = await probeTask;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            snapshot = null;
        }

        try
        {
            await guardTask;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
        }

        if (_disposed || cancellationToken.IsCancellationRequested || generation != _refreshGeneration)
        {
            return;
        }

        if (snapshot is null)
        {
            ApplyUnavailableProbe();
        }
        else
        {
            Apply(snapshot);
        }
        LastUpdated = $"更新于 {DateTime.Now:HH:mm:ss}";
    }

    public async Task RefreshGuardStatusAsync(CancellationToken cancellationToken = default)
    {
        var revision = _guardRevision;
        var status = await _guardStatusResolver(cancellationToken);
        if (!_disposed && !IsGuardBusy && !cancellationToken.IsCancellationRequested && revision == _guardRevision)
            ApplyGuard(status);
    }

    public Task ToggleGuardAsync(Func<GuardApplicationRequest, Task<string?>>? chooseApplication = null) =>
        ChangeGuardAsync(!_guardStatus.IsEnabled, chooseApplication);

    public Task EnableGuardAsync(Func<GuardApplicationRequest, Task<string?>>? chooseApplication = null) =>
        ChangeGuardAsync(true, chooseApplication);

    public Task SwitchGuardApplicationAsync(Func<GuardApplicationRequest, Task<string?>> chooseApplication) =>
        ChangeGuardAsync(true, chooseApplication, reconfigure: true, forceChoice: true);

    private async Task ChangeGuardAsync(bool enable,
        Func<GuardApplicationRequest, Task<string?>>? chooseApplication = null, bool reconfigure = false, bool forceChoice = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (IsGuardBusy) throw new InvalidOperationException("断网保护正在处理，请稍候。");
        IsGuardBusy = true;
        ++_guardRevision; // Reject an in-flight refresh's stale pre-mutation Guard status.
        try
        {
            var before = await _guardStatusResolver(_lifetimeCancellation.Token);
            ApplyGuard(before);
            if (before.Kind == GuardStatusKind.Unavailable) throw new GuardCommandException("SERVICE_UNAVAILABLE");
            if (!before.OwnedByCurrentUser) throw new GuardCommandException("OWNER_MISMATCH");
            if (enable && before.Kind == GuardStatusKind.Enabled && !reconfigure) return;
            if (!enable)
            {
                await _disableGuard(_lifetimeCancellation.Token);
                _activeGuardApplication = null;
            }
            else
            {
                async Task<string?> ChooseAndRemember(GuardApplicationRequest request)
                {
                    var path = await chooseApplication!(request);
                    if (path is not null)
                    {
                        var config = _config.Clone();
                        config.ProxyExecutablePath = ProxyApplicationSelection.NormalizePath(path);
                        if (config.ProxyExecutablePath.Length == 0) throw new GuardCommandException("INVALID_PROXY_PATH");
                        if (_config.ProxyExecutablePath.Length > 0 || !GuardActivationService.IsKnownCore(config.ProxyExecutablePath))
                        {
                            _configService.Save(config);
                            _config = config;
                        } // Choosing the current known core in auto mode does not pin future switches.
                    }
                    return path;
                }
                var path = await _guardActivation.EnableAsync(_config.ProxyExecutablePath,
                    chooseApplication is null ? null : ChooseAndRemember, _lifetimeCancellation.Token, forceChoice);
                if (path is null) return;
                _activeGuardApplication = path;
            }
            var status = await _guardStatusResolver(_lifetimeCancellation.Token);
            if (!_disposed)
            {
                ApplyGuard(status);
            }
            if (status.Kind != (enable ? GuardStatusKind.Enabled : GuardStatusKind.Disabled))
                throw new GuardCommandException(status.Kind == GuardStatusKind.Unavailable ? "SERVICE_UNAVAILABLE" : "FILTER_FAULT");
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            // Window disposal cancels in-flight Guard requests and suppresses late state changes.
        }
        catch
        {
            // An uncertain reply may follow a committed transaction: display the actual state.
            try
            {
                var status = await _guardStatusResolver(_lifetimeCancellation.Token);
                if (!_disposed) ApplyGuard(status);
            }
            catch { /* Preserve the original operation error. */ }
            throw;
        }
        finally
        {
            ++_guardRevision;
            IsGuardBusy = false;
            OnPropertyChanged(nameof(GuardEnabled)); // Reset the toggle after cancel/error, even if the value is unchanged.
            if (!_disposed)
            {
                _ = StartRefreshLoopIfNeeded();
            }
        }
    }

    public Task ReconfigureGuardAsync()
    {
        if (_disposed || !_guardStatus.IsEnabled || !_guardStatus.OwnedByCurrentUser)
        {
            return Task.CompletedTask;
        }
        return ChangeGuardAsync(true, reconfigure: true);
    }

    public async Task<HealthReport?> RunHealthCheckAsync()
    {
        if (_disposed || IsBusy || IsGuardBusy)
        {
            return null;
        }

        IsBusy = true;
        IsHealthCheckRunning = true;
        HealthButtonLabel = "检测中";
        var refreshAfterCompletion = false;
        try
        {
            var report = await _healthCheckAsync(
                _config.Clone(),
                _lifetimeCancellation.Token);
            refreshAfterCompletion = true;
            return report;
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            HealthButtonLabel = "检测";
            IsHealthCheckRunning = false;
            IsBusy = false;
            if (!_disposed && refreshAfterCompletion)
            {
                _ = RefreshAsync();
            }
            else if (!_disposed)
            {
                _ = StartRefreshLoopIfNeeded();
            }
        }
    }

    public AppConfig GetEditableConfig() => _config.Clone();

    public void SaveConfig(AppConfig config)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _configService.Save(config);
        if (!_configService.TryLoad(out var savedConfig))
        {
            throw new InvalidDataException("已写入的配置无法通过完整性校验。");
        }
        _config = savedConfig;
        OnPropertyChanged(nameof(Endpoint));
        OnPropertyChanged(nameof(PlanSummary));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetimeCancellation.Cancel();
        _exitSettlementCancellation?.Cancel();
        _exitSettlementCancellation?.Dispose();
        _refreshGeneration++;
        _exitRefreshGeneration++;
        _refreshRequested = false;
        _activeRefreshCancellation?.Cancel();
        _activeExitRefreshCancellation?.Cancel();
    }

    private static Task<T> InvokeSafely<T>(Func<Task<T>> factory)
    {
        try
        {
            return factory();
        }
        catch (Exception exception)
        {
            return Task.FromException<T>(exception);
        }
    }

    private void Apply(ProxySnapshot snapshot)
    {
        _proxyStatusAvailable = true;
        _connectionHasSystemProxy = snapshot.SystemProxyEnabled;
        _connectionHasVirtualAdapter = snapshot.VirtualNetworkDetected || snapshot.TunDetected ||
            snapshot.OtherTunnelDetected || snapshot.SplitTunnelDetected;
        _detectedClientName = snapshot.DetectedClientName;
        Headline = snapshot.Headline;
        Detail = snapshot.Detail;
        OverallLevel = snapshot.OverallLevel;
        Core.Update(snapshot.Core);
        Port.Update(snapshot.Port);
        Route.Update(snapshot.Route);
        OnPropertyChanged(nameof(ConnectionValue));
        OnPropertyChanged(nameof(ConnectionLevel));
        OnPropertyChanged(nameof(ConnectionBrush));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private void ApplyUnavailableProbe()
    {
        _proxyStatusAvailable = false;
        _connectionHasSystemProxy = false;
        _connectionHasVirtualAdapter = false;
        _detectedClientName = null;
        Headline = "暂时无法读取状态";
        Detail = "请稍后刷新，或检查 Windows 网络组件";
        OverallLevel = HealthLevel.Error;
        Core.Update(new MetricSnapshot("代理核心", "状态不可用", "检测失败", "核", HealthLevel.Error));
        Port.Update(new MetricSnapshot("本地端口", "状态不可用", Endpoint, "端", HealthLevel.Error));
        Route.Update(new MetricSnapshot("流量入口", "状态不可用", "系统路径检测失败", "入", HealthLevel.Error));
        OnPropertyChanged(nameof(ConnectionValue));
        OnPropertyChanged(nameof(ConnectionLevel));
        OnPropertyChanged(nameof(ConnectionBrush));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private void ApplyGuard(GuardStatus status)
    {
        _guardStatus = status;
        if (status.ProxyExecutablePath.Length > 0) _activeGuardApplication = status.ProxyExecutablePath;
        else if (!status.IsEnabled) _activeGuardApplication = null;
        OnPropertyChanged(nameof(GuardValue));
        OnPropertyChanged(nameof(GuardDetail));
        OnPropertyChanged(nameof(GuardButtonLabel));
        OnPropertyChanged(nameof(GuardEnabled));
        OnPropertyChanged(nameof(CanChangeGuard));
        OnPropertyChanged(nameof(GuardLevelBrush));
        OnPropertyChanged(nameof(GuardApplicationLabel));
        OnPropertyChanged(nameof(ShowGuardApplicationAction));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private void ApplyExit(ExitSummary summary)
    {
        _exitSummary = summary;
        OnPropertyChanged(nameof(ExitAddress));
        OnPropertyChanged(nameof(ExitLocation));
        OnPropertyChanged(nameof(ExitIpVersion));
        OnPropertyChanged(nameof(HasExitIpVersion));
        OnPropertyChanged(nameof(ConnectionValue));
        OnPropertyChanged(nameof(ConnectionLevel));
        OnPropertyChanged(nameof(ConnectionBrush));
        OnPropertyChanged(nameof(ConnectionDetail));
    }
}
