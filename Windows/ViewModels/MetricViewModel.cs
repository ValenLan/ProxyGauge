using System.Windows.Media;
using ProxyGauge.Models;

namespace ProxyGauge.ViewModels;

public sealed class MetricViewModel : ObservableObject
{
    private string _title;
    private string _value;
    private string _detail;
    private string _marker;
    private HealthLevel _level;

    public MetricViewModel(MetricSnapshot snapshot)
    {
        _title = snapshot.Title;
        _value = snapshot.Value;
        _detail = snapshot.Detail;
        _marker = snapshot.Marker;
        _level = snapshot.Level;
    }

    public string Title { get => _title; private set => SetProperty(ref _title, value); }
    public string Value { get => _value; private set => SetProperty(ref _value, value); }
    public string Detail { get => _detail; private set => SetProperty(ref _detail, value); }
    public string Marker { get => _marker; private set => SetProperty(ref _marker, value); }
    public HealthLevel Level
    {
        get => _level;
        private set
        {
            if (SetProperty(ref _level, value))
            {
                OnPropertyChanged(nameof(LevelBrush));
                OnPropertyChanged(nameof(LevelBackground));
            }
        }
    }

    public Brush LevelBrush => Palette.ForLevel(Level);
    public Brush LevelBackground => Palette.BackgroundForLevel(Level);

    public void Update(MetricSnapshot snapshot)
    {
        Title = snapshot.Title;
        Value = snapshot.Value;
        Detail = snapshot.Detail;
        Marker = snapshot.Marker;
        Level = snapshot.Level;
    }
}

public static class Palette
{
    public static readonly Brush Accent = Create("#218CFF");
    public static readonly Brush Success = Create("#33C759");
    public static readonly Brush Warning = Create("#FF9F0A");
    public static readonly Brush Error = Create("#FF453A");
    public static readonly Brush Idle = Create("#8E8E93");

    private static readonly Brush SuccessBackground = Create("#2433C759");
    private static readonly Brush WarningBackground = Create("#24FF9F0A");
    private static readonly Brush ErrorBackground = Create("#24FF453A");
    private static readonly Brush IdleBackground = Create("#248E8E93");

    public static Brush ForLevel(HealthLevel level) => level switch
    {
        HealthLevel.Ok => Success,
        HealthLevel.Warning => Warning,
        HealthLevel.Error => Error,
        _ => Idle
    };

    public static Brush BackgroundForLevel(HealthLevel level) => level switch
    {
        HealthLevel.Ok => SuccessBackground,
        HealthLevel.Warning => WarningBackground,
        HealthLevel.Error => ErrorBackground,
        _ => IdleBackground
    };

    private static Brush Create(string value)
    {
        var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(value)!;
        brush.Freeze();
        return brush;
    }
}
