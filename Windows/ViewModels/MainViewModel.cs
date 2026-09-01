using System.Windows.Media;
using ProxyGauge.Models;
using ProxyGauge.Services;

namespace ProxyGauge.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private readonly ConfigService _configService;
    private readonly ProxyProbeService _probeService;
    private readonly HealthCheckService _healthCheckService;
    private readonly GuardClient _guardClient;
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

    public MainViewModel(
        ConfigService configService,
        ProxyProbeService probeService,
        HealthCheckService healthCheckService,
        GuardClient guardClient)
    {
        _configService = configService;
        _probeService = probeService;
        _healthCheckService = healthCheckService;
        _guardClient = guardClient;
        _config = _configService.Load();

        Core = new MetricViewModel(new MetricSnapshot("代理核心", "检查中", "正在查找 Mihomo", "核", HealthLevel.Idle));
        Port = new MetricViewModel(new MetricSnapshot("本地端口", "检查中", $"{_config.MixedHost}:{_config.MixedPort}", "端", HealthLevel.Idle));
        Route = new MetricViewModel(new MetricSnapshot("流量入口", "检查中", "系统代理或 TUN", "入", HealthLevel.Idle));
    }

    public MetricViewModel Core { get; }
    public MetricViewModel Port { get; }
    public MetricViewModel Route { get; }
    public string Headline { get => _headline; private set => SetProperty(ref _headline, value); }
    public string Detail { get => _detail; private set => SetProperty(ref _detail, value); }
    public string HealthButtonLabel { get => _healthButtonLabel; private set => SetProperty(ref _healthButtonLabel, value); }
    public string LastUpdated { get => _lastUpdated; private set => SetProperty(ref _lastUpdated, value); }
    public string Endpoint => $"{_config.MixedHost}:{_config.MixedPort}";
    public string ConnectionValue => OverallLevel switch
    {
        HealthLevel.Ok => "已连接",
        HealthLevel.Warning => Headline,
        HealthLevel.Error => "未连接",
        _ => "检查中"
    };
    public string ConnectionDetail
    {
        get
        {
            var mode = Route.Title switch
            {
                "TUN 路由" => "TUN",
                "系统代理" => "系统代理",
                "双重入口" => "系统代理 + TUN",
                _ => Route.Title
            };
            return $"Mihomo · {mode} · {Endpoint}";
        }
    }
    public string ExitAddress => _exitSummary.Address;
    public string ExitLocation => _exitSummary.Location;
    public string ExitNetwork => _exitSummary.Network;
    public string ExitNetworkType => _exitSummary.NetworkType;
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

    public bool IsNotBusy => !IsBusy;
    public bool IsGuardBusy
    {
        get => _isGuardBusy;
        private set
        {
            if (SetProperty(ref _isGuardBusy, value))
            {
                OnPropertyChanged(nameof(GuardButtonLabel));
                OnPropertyChanged(nameof(CanChangeGuard));
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

    public async Task RefreshAsync()
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        var guardTask = _guardClient.GetStatusAsync();
        var exitTask = ExitSummaryService.ResolveAsync(_config);
        try
        {
            var snapshot = await _probeService.ProbeAsync(_config);
            Apply(snapshot);
            LastUpdated = $"更新于 {DateTime.Now:HH:mm:ss}";
        }
        catch
        {
            Headline = "暂时无法读取状态";
            Detail = "请稍后刷新，或检查 Windows 网络组件";
            OverallLevel = HealthLevel.Error;
        }
        finally
        {
            try
            {
                ApplyExit(await exitTask);
            }
            catch
            {
                ApplyExit(ExitSummary.Unavailable());
            }
            ApplyGuard(await guardTask);
            IsBusy = false;
        }
    }

    public async Task ToggleGuardAsync()
    {
        if (!CanChangeGuard)
        {
            return;
        }

        IsGuardBusy = true;
        try
        {
            if (_guardStatus.IsEnabled)
            {
                await _guardClient.DisableAsync();
            }
            else
            {
                await _guardClient.EnableAsync(_config.MixedPort);
            }
            ApplyGuard(await _guardClient.GetStatusAsync());
        }
        finally
        {
            IsGuardBusy = false;
        }
    }

    public async Task ReconfigureGuardAsync()
    {
        if (!_guardStatus.IsEnabled || !_guardStatus.OwnedByCurrentUser)
        {
            return;
        }

        IsGuardBusy = true;
        try
        {
            await _guardClient.EnableAsync(_config.MixedPort);
            ApplyGuard(await _guardClient.GetStatusAsync());
        }
        finally
        {
            IsGuardBusy = false;
        }
    }

    public async Task<HealthReport?> RunHealthCheckAsync()
    {
        if (IsBusy)
        {
            return null;
        }

        IsBusy = true;
        IsHealthCheckRunning = true;
        HealthButtonLabel = "检测中";
        try
        {
            var report = await _healthCheckService.RunAsync(_config);
            await RefreshAfterHealthCheckAsync();
            return report;
        }
        finally
        {
            HealthButtonLabel = "检测";
            IsHealthCheckRunning = false;
            IsBusy = false;
        }
    }

    public AppConfig GetEditableConfig() => _config.Clone();

    public void SaveConfig(AppConfig config)
    {
        _configService.Save(config);
        _config = _configService.Load();
        OnPropertyChanged(nameof(Endpoint));
        OnPropertyChanged(nameof(PlanSummary));
        OnPropertyChanged(nameof(ConnectionDetail));
    }

    private async Task RefreshAfterHealthCheckAsync()
    {
        try
        {
            var snapshot = await _probeService.ProbeAsync(_config);
            Apply(snapshot);
            LastUpdated = $"更新于 {DateTime.Now:HH:mm:ss}";
        }
        catch
        {
            // The completed health report remains useful if the compact refresh fails.
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
        OnPropertyChanged(nameof(ExitNetwork));
        OnPropertyChanged(nameof(ExitNetworkType));
    }
}
