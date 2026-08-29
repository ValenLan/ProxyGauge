using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace ProxyGauge.Services;

public enum AppThemeKind
{
    Light,
    Dark,
    HighContrast
}

public sealed class ThemeService : IDisposable
{
    private bool _started;

    public AppThemeKind CurrentTheme { get; private set; } = AppThemeKind.Dark;

    public void Start()
    {
        if (_started)
        {
            return;
        }

        _started = true;
        ApplyCurrentTheme();
        SystemEvents.UserPreferenceChanged += SystemEvents_UserPreferenceChanged;
    }

    public void Dispose()
    {
        if (!_started)
        {
            return;
        }

        SystemEvents.UserPreferenceChanged -= SystemEvents_UserPreferenceChanged;
        _started = false;
    }

    public static AppThemeKind ResolveTheme(bool highContrast, object? appsUseLightTheme)
    {
        if (highContrast)
        {
            return AppThemeKind.HighContrast;
        }

        return appsUseLightTheme switch
        {
            int value when value == 0 => AppThemeKind.Dark,
            long value when value == 0 => AppThemeKind.Dark,
            string value when value == "0" => AppThemeKind.Dark,
            _ => AppThemeKind.Light
        };
    }

    public static IReadOnlyDictionary<string, string> GetPalette(AppThemeKind theme) => theme switch
    {
        AppThemeKind.Light => LightPalette,
        AppThemeKind.HighContrast => CreateHighContrastPalette(),
        _ => DarkPalette
    };

    private void SystemEvents_UserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (Application.Current?.Dispatcher is not { } dispatcher)
        {
            return;
        }

        dispatcher.BeginInvoke(new Action(ApplyCurrentTheme));
    }

    private void ApplyCurrentTheme()
    {
        if (Application.Current is not { } application)
        {
            return;
        }

        CurrentTheme = ResolveTheme(SystemParameters.HighContrast, ReadAppsUseLightTheme());
        foreach (var (key, value) in GetPalette(CurrentTheme))
        {
            application.Resources[key] = (Color)ColorConverter.ConvertFromString(value);
        }
    }

    private static object? ReadAppsUseLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme");
        }
        catch
        {
            // A locked-down profile should remain usable. Windows defaults to light.
            return null;
        }
    }

    private static IReadOnlyDictionary<string, string> CreateHighContrastPalette()
    {
        var window = Hex(SystemColors.WindowColor);
        var windowText = Hex(SystemColors.WindowTextColor);
        var control = Hex(SystemColors.ControlColor);
        var highlight = Hex(SystemColors.HighlightColor);
        var highlightText = Hex(SystemColors.HighlightTextColor);

        return new Dictionary<string, string>(LightPalette)
        {
            ["CanvasColor"] = window,
            ["SurfaceColor"] = control,
            ["SurfaceRaisedColor"] = control,
            ["SurfaceSubtleColor"] = control,
            ["ControlColor"] = control,
            ["ControlHoverColor"] = highlight,
            ["FieldColor"] = window,
            ["BorderColor"] = windowText,
            ["TextColor"] = windowText,
            ["MutedTextColor"] = windowText,
            ["SubtleTextColor"] = windowText,
            ["AccentColor"] = highlight,
            ["AccentStrongColor"] = highlight,
            ["AccentHoverColor"] = highlight,
            ["AccentFocusColor"] = highlightText,
            ["OnAccentColor"] = highlightText,
            ["AccentSurfaceColor"] = control,
            ["AccentTintColor"] = control,
            ["SuccessColor"] = windowText,
            ["WarningColor"] = windowText,
            ["ErrorColor"] = windowText,
            ["IdleColor"] = windowText,
            ["SuccessBackgroundColor"] = control,
            ["WarningBackgroundColor"] = control,
            ["ErrorBackgroundColor"] = control,
            ["IdleBackgroundColor"] = control,
            ["RulesColor"] = highlight,
            ["RulesSurfaceColor"] = control,
            ["AdvancedColor"] = highlight,
            ["AdvancedSurfaceColor"] = control,
            ["SwitchTrackColor"] = control,
            ["SwitchThumbColor"] = windowText,
            ["ProgressTrackColor"] = control
        };
    }

    private static string Hex(Color color) =>
        $"#{color.A:X2}{color.R:X2}{color.G:X2}{color.B:X2}";

    private static readonly IReadOnlyDictionary<string, string> DarkPalette =
        new Dictionary<string, string>
        {
            ["CanvasColor"] = "#FF242424",
            ["SurfaceColor"] = "#FF1C1C1C",
            ["SurfaceRaisedColor"] = "#FF2A2A2A",
            ["SurfaceSubtleColor"] = "#FF202020",
            ["ControlColor"] = "#FF2C2C2E",
            ["ControlHoverColor"] = "#FF3A3A3C",
            ["FieldColor"] = "#FF141414",
            ["BorderColor"] = "#14FFFFFF",
            ["TextColor"] = "#FFECECEC",
            ["MutedTextColor"] = "#FF9C9CA1",
            ["SubtleTextColor"] = "#FF62748A",
            ["AccentColor"] = "#FF218CFF",
            ["AccentStrongColor"] = "#FF0A84FF",
            ["AccentHoverColor"] = "#FF3D9DFF",
            ["AccentFocusColor"] = "#FFD9EBFF",
            ["OnAccentColor"] = "#FFFFFFFF",
            ["AccentSurfaceColor"] = "#FF20375A",
            ["AccentTintColor"] = "#223D76AD",
            ["SuccessColor"] = "#FF33C759",
            ["WarningColor"] = "#FFFF9F0A",
            ["ErrorColor"] = "#FFFF453A",
            ["IdleColor"] = "#FF8E8E93",
            ["SuccessBackgroundColor"] = "#2433C759",
            ["WarningBackgroundColor"] = "#24FF9F0A",
            ["ErrorBackgroundColor"] = "#24FF453A",
            ["IdleBackgroundColor"] = "#248E8E93",
            ["RulesColor"] = "#FF8A6BF5",
            ["RulesSurfaceColor"] = "#FF262040",
            ["AdvancedColor"] = "#FF33B8D1",
            ["AdvancedSurfaceColor"] = "#FF1D3038",
            ["SwitchTrackColor"] = "#FF3A3A3C",
            ["SwitchThumbColor"] = "#FFF5F5F7",
            ["ProgressTrackColor"] = "#FF26354A"
        };

    private static readonly IReadOnlyDictionary<string, string> LightPalette =
        new Dictionary<string, string>
        {
            ["CanvasColor"] = "#FFF3F5F7",
            ["SurfaceColor"] = "#FFFFFFFF",
            ["SurfaceRaisedColor"] = "#FFF8FAFC",
            ["SurfaceSubtleColor"] = "#FFEAF0F5",
            ["ControlColor"] = "#FFEEF1F5",
            ["ControlHoverColor"] = "#FFE1E6EC",
            ["FieldColor"] = "#FFFFFFFF",
            ["BorderColor"] = "#1F1B2430",
            ["TextColor"] = "#FF1B1D22",
            ["MutedTextColor"] = "#FF666A73",
            ["SubtleTextColor"] = "#FF7D8591",
            ["AccentColor"] = "#FF006FD6",
            ["AccentStrongColor"] = "#FF005FB8",
            ["AccentHoverColor"] = "#FF005EBA",
            ["AccentFocusColor"] = "#FF0B3158",
            ["OnAccentColor"] = "#FFFFFFFF",
            ["AccentSurfaceColor"] = "#FFE2F0FF",
            ["AccentTintColor"] = "#1A006FD6",
            ["SuccessColor"] = "#FF18864B",
            ["WarningColor"] = "#FF9B5C00",
            ["ErrorColor"] = "#FFC9362B",
            ["IdleColor"] = "#FF6F737B",
            ["SuccessBackgroundColor"] = "#2418864B",
            ["WarningBackgroundColor"] = "#249B5C00",
            ["ErrorBackgroundColor"] = "#24C9362B",
            ["IdleBackgroundColor"] = "#246F737B",
            ["RulesColor"] = "#FF6B52D9",
            ["RulesSurfaceColor"] = "#FFEEEAFE",
            ["AdvancedColor"] = "#FF087F98",
            ["AdvancedSurfaceColor"] = "#FFE2F5F8",
            ["SwitchTrackColor"] = "#FFC4C9D0",
            ["SwitchThumbColor"] = "#FFFFFFFF",
            ["ProgressTrackColor"] = "#FFDCE3EA"
        };
}
