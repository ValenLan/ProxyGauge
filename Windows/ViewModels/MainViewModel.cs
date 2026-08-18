using System.Windows.Media;
using CloudRoute.Models;
using CloudRoute.Services;

namespace CloudRoute.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private readonly ConfigService _configService;
    private readonly ProxyProbeService _probeService;
    private readonly HealthCheckService _healthCheckService;
    private AppConfig _config;
    private string _headline = "正在读取代理状态";
    private string _detail = "稍等片刻，CloudRoute 正在检查本地流量入口";
    private HealthLevel _overallLevel = HealthLevel.Idle;
    private bool _isBusy;
    private bool _isHealthCheckRunning;
    private string _healthButtonLabel = "开始检查";
    private string _lastUpdated = "尚未刷新";

    public MainViewModel(
        ConfigService configService,
        ProxyProbeService probeService,
        HealthCheckService healthCheckService)
    {
        _configService = configService;
        _probeService = probeService;
        _healthCheckService = healthCheckService;
        _config = _configService.Load();

        Core = new MetricViewModel(new MetricSnapshot("代理核心", "检查中", "正在查找 Mihomo", "核", HealthLevel.Idle));
        Port = new MetricViewModel(new MetricSnapshot("本地端口", "检查中", $"{_config.MixedHost}:{_config.MixedPort}", "端", HealthLevel.Idle));
        Route = new MetricViewModel(new MetricSnapshot("流量入口", "检查中", "系统代理或 TUN", "路", HealthLevel.Idle));
    }

    public MetricViewModel Core { get; }
    public MetricViewModel Port { get; }
    public MetricViewModel Route { get; }
    public string Headline { get => _headline; private set => SetProperty(ref _headline, value); }
    public string Detail { get => _detail; private set => SetProperty(ref _detail, value); }
    public string HealthButtonLabel { get => _healthButtonLabel; private set => SetProperty(ref _healthButtonLabel, value); }
    public string LastUpdated { get => _lastUpdated; private set => SetProperty(ref _lastUpdated, value); }
    public string Endpoint => $"{_config.MixedHost}:{_config.MixedPort}";

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
            }
        }
    }

    public bool IsNotBusy => !IsBusy;
    public bool IsHealthCheckRunning
    {
        get => _isHealthCheckRunning;
        private set => SetProperty(ref _isHealthCheckRunning, value);
    }

    public async Task RefreshAsync()
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
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
            IsBusy = false;
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
        HealthButtonLabel = "正在检查…";
        try
        {
            var report = await _healthCheckService.RunAsync(_config);
            await RefreshAfterHealthCheckAsync();
            return report;
        }
        finally
        {
            HealthButtonLabel = "开始检查";
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
    }
}
