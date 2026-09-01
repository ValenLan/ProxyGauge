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
    private const string RegistryPath = @"Software\ProxyGauge";
    private const string ThemeValueName = "Theme";
    private bool _started;

    public AppThemeKind CurrentTheme { get; private set; } = AppThemeKind.Light;

    public void Start()
    {
        if (_started)
        {
            return;
        }

        _started = true;
        ApplyTheme(ResolveTheme(SystemParameters.HighContrast, ReadSavedTheme()));
    }

    public void Dispose()
    {
        if (!_started)
        {
            return;
        }

        _started = false;
    }

    public AppThemeKind ToggleTheme()
    {
        var selected = CurrentTheme == AppThemeKind.Dark
            ? AppThemeKind.Light
            : AppThemeKind.Dark;
        SaveTheme(selected);
        ApplyTheme(SystemParameters.HighContrast ? AppThemeKind.HighContrast : selected);
        return CurrentTheme;
    }

    public static AppThemeKind ResolveTheme(bool highContrast, string? savedTheme)
    {
        if (highContrast)
        {
            return AppThemeKind.HighContrast;
        }

        return string.Equals(savedTheme, "dark", StringComparison.OrdinalIgnoreCase)
            ? AppThemeKind.Dark
            : AppThemeKind.Light;
    }

    public static IReadOnlyDictionary<string, string> GetPalette(AppThemeKind theme) => theme switch
    {
        AppThemeKind.Light => LightPalette,
        AppThemeKind.HighContrast => CreateHighContrastPalette(),
        _ => DarkPalette
    };

    public static void ApplyPalette(
        ResourceDictionary resources,
        IReadOnlyDictionary<string, string> palette)
    {
        foreach (var (key, value) in palette)
        {
            var color = (Color)ColorConverter.ConvertFromString(value);
            resources[key] = color;

            var brushKey = key.EndsWith("Color", StringComparison.Ordinal)
                ? $"{key[..^"Color".Length]}Brush"
                : $"{key}Brush";
            resources[brushKey] = new SolidColorBrush(color);
        }
    }

    private void ApplyTheme(AppThemeKind theme)
    {
        if (Application.Current is not { } application)
        {
            return;
        }

        CurrentTheme = theme;
        ApplyPalette(application.Resources, GetPalette(CurrentTheme));
    }

    private static string? ReadSavedTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(ThemeValueName) as string;
        }
        catch
        {
            return null;
        }
    }

    private static void SaveTheme(AppThemeKind theme)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            key?.SetValue(
                ThemeValueName,
                theme == AppThemeKind.Dark ? "dark" : "light",
                RegistryValueKind.String);
        }
        catch
        {
            // A locked-down profile still receives the selected theme for this session.
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
            ["CanvasColor"] = "#FF181A1C",
            ["SurfaceColor"] = "#FF202324",
            ["SurfaceRaisedColor"] = "#FF25292A",
            ["SurfaceSubtleColor"] = "#FF1D2022",
            ["ControlColor"] = "#FF25292A",
            ["ControlHoverColor"] = "#FF2C3130",
            ["FieldColor"] = "#FF151719",
            ["BorderColor"] = "#FF343A38",
            ["TextColor"] = "#FFE7EAE9",
            ["MutedTextColor"] = "#FF989E9B",
            ["SubtleTextColor"] = "#FF626866",
            ["AccentColor"] = "#FF36EC8F",
            ["AccentStrongColor"] = "#FF25D87B",
            ["AccentHoverColor"] = "#FF57F3A2",
            ["AccentFocusColor"] = "#FFC5FFE0",
            ["OnAccentColor"] = "#FF0D1712",
            ["AccentSurfaceColor"] = "#FF1E352A",
            ["AccentTintColor"] = "#2236EC8F",
            ["SuccessColor"] = "#FF36EC8F",
            ["WarningColor"] = "#FFFF9F0A",
            ["ErrorColor"] = "#FFFF453A",
            ["IdleColor"] = "#FF8E8E93",
            ["SuccessBackgroundColor"] = "#2436EC8F",
            ["WarningBackgroundColor"] = "#24FF9F0A",
            ["ErrorBackgroundColor"] = "#24FF453A",
            ["IdleBackgroundColor"] = "#248E8E93",
            ["RulesColor"] = "#FF36EC8F",
            ["RulesSurfaceColor"] = "#FF1E352A",
            ["AdvancedColor"] = "#FF36EC8F",
            ["AdvancedSurfaceColor"] = "#FF1E352A",
            ["SwitchTrackColor"] = "#FF343A38",
            ["SwitchThumbColor"] = "#FFE7EAE9",
            ["ProgressTrackColor"] = "#FF25312C"
        };

    private static readonly IReadOnlyDictionary<string, string> LightPalette =
        new Dictionary<string, string>
        {
            ["CanvasColor"] = "#FFFFFFFF",
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
