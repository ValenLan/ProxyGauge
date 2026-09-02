using System.IO;
using System.Windows.Media;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge.ViewModels;

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly ConfigService _configService;
    private readonly GuardClient _guardClient;
    private readonly Func<AppConfig, CancellationToken, Task<ProxySnapshot>> _probeAsync;
    private readonly Func<AppConfig, CancellationToken, Task<ExitSummary>> _exitResolver;
    private readonly Func<CancellationToken, Task<GuardStatus>> _guardStatusResolver;
    private readonly Func<AppConfig, CancellationToken, Task<HealthReport>> _healthCheckAsync;
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
    private ExitSummary _exitSummary = ExitSummary.Unavailable();
    private CancellationTokenSource? _activeRefreshCancellation;
    private Task _refreshLoopTask = Task.CompletedTask;
    private long _refreshGeneration;
    private bool _refreshRequested;
    private bool _disposed;

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
        Func<AppConfig, CancellationToken, Task<HealthReport>>? healthCheckAsync = null)
    {
        _configService = configService;
        _guardClient = guardClient;
        _probeAsync = probeAsync;
        _exitResolver = exitResolver;
        _guardStatusResolver = guardStatusResolver;
        _healthCheckAsync = healthCheckAsync ?? healthCheckService.RunAsync;
        _config = _configService.Load();

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
    public string ConnectionValue => OverallLevel switch
    {
        HealthLevel.Ok => "已连接",
        HealthLevel.Warning => Headline,
        HealthLevel.Error => "未连接",
        _ => "检查中"
    };
    public string ConnectionDetail
    {
        get => BuildConnectionDetail(
            Route.Title,
            Route.Value,
            Core.Level,
            Port.Level,
            Endpoint);
    }

    internal static string BuildConnectionDetail(
        string routeTitle,
        string routeValue,
        HealthLevel coreLevel,
        HealthLevel portLevel,
        string endpoint)
    {
        if (routeTitle.Contains("其他 VPN / TUN", StringComparison.Ordinal))
        {
            return routeTitle.Contains("系统代理", StringComparison.Ordinal)
                ? "其他 VPN / TUN · 与系统代理并存"
                : "其他 VPN / TUN · 系统路径";
        }
        var mode = routeTitle switch
        {
            "TUN 路由" => "TUN",
            "系统代理" => "系统代理",
            "PAC 代理" => "PAC",
            "自动代理" => "WPAD",
            "双重入口" => "系统代理 + TUN",
            "系统代理 + TUN" => "系统代理 + TUN",
            _ => routeTitle
        };
        var mihomoCoreHealthy = coreLevel == HealthLevel.Ok;
        var localMihomoEndpointHealthy = mihomoCoreHealthy && portLevel == HealthLevel.Ok;
        if (mihomoCoreHealthy &&
            routeTitle == "TUN 路由" &&
            routeValue == "代表性路由已确认")
        {
            return localMihomoEndpointHealthy
                ? $"Mihomo · TUN · {endpoint}"
                : "Mihomo · TUN-only";
        }

        var verifiedMihomoPath = localMihomoEndpointHealthy &&
             (routeTitle == "双重入口" && routeValue == "同时开启" ||
              routeTitle == "系统代理" && routeValue == "已启用");
        return verifiedMihomoPath
            ? $"Mihomo · {mode} · {endpoint}"
            : $"系统路径 · {mode}";
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
        GuardStatusKind.Enabled => "退出 ProxyGauge 后仍持续拦截直连；代理核心停止时会断网而非裸连",
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
    public bool CanChangeGuard => !IsBusy && !_isGuardBusy &&
        _guardStatus.Kind != GuardStatusKind.Unavailable &&
        _guardStatus.OwnedByCurrentUser;

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
        ApplyExit(ExitSummary.Checking());
        _activeRefreshCancellation?.Cancel();
        return StartRefreshLoopIfNeeded();
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

    public void InvalidateExitSummary()
    {
        if (_disposed)
        {
            return;
        }

        _refreshGeneration++;
        ApplyExit(ExitSummary.Checking());
        _activeRefreshCancellation?.Cancel();
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
        var guardTask = InvokeSafely(() => _guardStatusResolver(cancellationToken));
        var exitTask = InvokeSafely(() => _exitResolver(config, cancellationToken));
        var probeTask = InvokeSafely(() => _probeAsync(config, cancellationToken));

        ProxySnapshot? snapshot = null;
        ExitSummary exitSummary = ExitSummary.Unavailable();
        GuardStatus guardStatus = GuardStatus.Unavailable();
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
            exitSummary = await exitTask;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            exitSummary = ExitSummary.Unavailable();
        }

        try
        {
            guardStatus = await guardTask;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            guardStatus = GuardStatus.Unavailable();
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
        ApplyExit(exitSummary);
        ApplyGuard(guardStatus);
        LastUpdated = $"更新于 {DateTime.Now:HH:mm:ss}";
    }

    public async Task ToggleGuardAsync()
    {
        if (_disposed || !CanChangeGuard)
        {
            return;
        }

        IsGuardBusy = true;
        try
        {
            if (_guardStatus.IsEnabled)
            {
                await _guardClient.DisableAsync(_lifetimeCancellation.Token);
            }
            else
            {
                await _guardClient.EnableAsync(_config.MixedPort, _lifetimeCancellation.Token);
            }
            var status = await _guardClient.GetStatusAsync(_lifetimeCancellation.Token);
            if (!_disposed)
            {
                ApplyGuard(status);
            }
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            // Window disposal cancels in-flight Guard requests and suppresses late state changes.
        }
        finally
        {
            IsGuardBusy = false;
            if (!_disposed)
            {
                _ = StartRefreshLoopIfNeeded();
            }
        }
    }

    public async Task ReconfigureGuardAsync()
    {
        if (_disposed || !_guardStatus.IsEnabled || !_guardStatus.OwnedByCurrentUser)
        {
            return;
        }

        IsGuardBusy = true;
        try
        {
            await _guardClient.EnableAsync(_config.MixedPort, _lifetimeCancellation.Token);
            var status = await _guardClient.GetStatusAsync(_lifetimeCancellation.Token);
            if (!_disposed)
            {
                ApplyGuard(status);
            }
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
            // Window disposal cancels in-flight Guard requests and suppresses late state changes.
        }
        finally
        {
            IsGuardBusy = false;
            if (!_disposed)
            {
                _ = StartRefreshLoopIfNeeded();
            }
        }
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
        InvalidateExitSummary();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetimeCancellation.Cancel();
        _refreshGeneration++;
        _refreshRequested = false;
        _activeRefreshCancellation?.Cancel();
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
        Headline = snapshot.Headline;
        Detail = snapshot.Detail;
        OverallLevel = snapshot.OverallLevel;
        Core.Update(snapshot.Core);
        Port.Update(snapshot.Port);
        Route.Update(snapshot.Route);
        OnPropertyChanged(nameof(ConnectionValue));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private void ApplyUnavailableProbe()
    {
        Headline = "暂时无法读取状态";
        Detail = "请稍后刷新，或检查 Windows 网络组件";
        OverallLevel = HealthLevel.Error;
        Core.Update(new MetricSnapshot("代理核心", "状态不可用", "检测失败", "核", HealthLevel.Error));
        Port.Update(new MetricSnapshot("本地端口", "状态不可用", Endpoint, "端", HealthLevel.Error));
        Route.Update(new MetricSnapshot("流量入口", "状态不可用", "系统路径检测失败", "入", HealthLevel.Error));
        OnPropertyChanged(nameof(ConnectionValue));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private void ApplyGuard(GuardStatus status)
    {
        _guardStatus = status;
        OnPropertyChanged(nameof(GuardValue));
        OnPropertyChanged(nameof(GuardDetail));
        OnPropertyChanged(nameof(GuardButtonLabel));
        OnPropertyChanged(nameof(GuardEnabled));
        OnPropertyChanged(nameof(CanChangeGuard));
        OnPropertyChanged(nameof(GuardLevelBrush));
    }

    private void ApplyExit(ExitSummary summary)
    {
        _exitSummary = summary;
        OnPropertyChanged(nameof(ExitAddress));
        OnPropertyChanged(nameof(ExitLocation));
        OnPropertyChanged(nameof(ExitIpVersion));
        OnPropertyChanged(nameof(HasExitIpVersion));
    }
}
