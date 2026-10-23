using System.Windows.Interop;

namespace PFlow.Windows;

internal static class PeshTheme
{
    public static Brush Gradient(Preferences preferences)
    {
        string[] colors = preferences.Palette switch {
            "pesh" => ["FF9DC4", "E04F8C", "7C4DFF", "52F0DD", "9DFF5C", "3DFF85"],
            "aurora" => ["4EE5B3", "65BFFF"], "solar" => ["FFBB66", "FF7188"], _ => [preferences.CustomAccent ?? preferences.Accent, preferences.WaveBlend]
        };
        if (colors.Length == 1) return Brush(colors[0]);
        double[] offsets = colors.Length == 6 ? [0, .14, .31, .50, .72, 1] : [0, 1];
        return new LinearGradientBrush(new GradientStopCollection(colors.Select((color, i) => new GradientStop(Parse(color), offsets[i]))), new Point(0, .375), new Point(1, .625));
    }
    static Color Parse(string value) => (Color)ColorConverter.ConvertFromString("#" + value);
    static SolidColorBrush Brush(string value) => new(Parse(value));
    static string AccentInk(string value) => Luminance(Parse(value)) > .179 ? "000000" : "FFFFFF";
    public static double Luminance(Color color)
    {
        double Channel(byte channel) { double c = channel / 255.0; return c <= .04045 ? c / 12.92 : Math.Pow((c + .055) / 1.055, 2.4); }
        return .2126 * Channel(color.R) + .7152 * Channel(color.G) + .0722 * Channel(color.B);
    }
    /// The least luminance a colour may have on the black capsule: 3:1 against black.
    public const double MinimumLuminanceOnBlack = .10;
    /// A colour too dark for the black capsule (a custom accent like 101010) is lifted toward
    /// white until it reaches MinimumLuminanceOnBlack; any other colour comes back unchanged.
    public static Color OnBlack(Color color)
    {
        if (Luminance(color) >= MinimumLuminanceOnBlack) return color;
        double low = 0, high = 1;
        for (int i = 0; i < 20; i++) { double t = (low + high) / 2; if (Luminance(Blend(color, t)) >= MinimumLuminanceOnBlack) high = t; else low = t; }
        return Blend(color, high);
    }
    static Color Blend(Color color, double t) => Color.FromRgb((byte)Math.Round(color.R + (255 - color.R) * t), (byte)Math.Round(color.G + (255 - color.G) * t), (byte)Math.Round(color.B + (255 - color.B) * t));
    public static Brush OnBlack(Brush brush) => brush switch {
        SolidColorBrush solid => new SolidColorBrush(OnBlack(solid.Color)),
        LinearGradientBrush gradient => new LinearGradientBrush(new GradientStopCollection(gradient.GradientStops.Select(stop => new GradientStop(OnBlack(stop.Color), stop.Offset))), gradient.StartPoint, gradient.EndPoint),
        _ => brush,
    };
    public static bool Light(Preferences preferences) => preferences.Theme == "light" || (preferences.Theme == "system" && Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0) is int mode && mode == 1);
    public static void Apply(Window window, Preferences preferences)
    {
        bool light = Light(preferences);
        var values = new Dictionary<string, string> {
            ["PeshBackground"] = light ? "F6F2F9" : "08070D", ["PeshText"] = light ? "20182A" : "DEDCE3",
            ["PeshMuted"] = light ? "685B74" : "A39EAD", ["PeshCard"] = light ? "C7FFFFFF" : "D91A1526",
            ["PeshInput"] = light ? "FCFAFE" : "120F1B", ["PeshBorder"] = light ? "D8CEDF" : "332D40",
            ["PeshToggleOff"] = light ? "E3DCEB" : "55475F", ["PeshTile"] = light ? "EDE8F2" : "1A1526", ["PeshSegment"] = light ? "E3DCEB" : "2B2634", ["PeshAccentInk"] = AccentInk(preferences.Accent),
            ["PeshHover"] = light ? "EFE7F7" : "2B203A", ["PeshSelection"] = light ? "EEDDFA" : "402E55", ["PeshAccent"] = preferences.Accent,
            // Floating card over other apps, and the recording dot (same red as the Mac Theme.recording).
            ["PeshFloating"] = light ? "FFFFFF" : "1A1526", ["PeshRecording"] = "E64A59"
        };
        foreach (var pair in values) window.Resources[pair.Key] = Brush(pair.Value);
        window.Background = (Brush)window.Resources["PeshBackground"]; window.Foreground = (Brush)window.Resources["PeshText"];
        window.Resources[SystemColors.ControlBrushKey] = window.Resources["PeshCard"]; window.Resources[SystemColors.ControlTextBrushKey] = window.Foreground;
        window.Resources[SystemColors.WindowBrushKey] = window.Resources["PeshInput"]; window.Resources[SystemColors.WindowTextBrushKey] = window.Foreground;
        window.Resources[SystemColors.HighlightBrushKey] = window.Resources["PeshSelection"]; window.Resources[SystemColors.HighlightTextBrushKey] = window.Foreground;
        var accent = Parse(preferences.Accent);
        var glow = new RadialGradientBrush(Color.FromArgb(light ? (byte)18 : (byte)26, accent.R, accent.G, accent.B), Colors.Transparent) {
            MappingMode = BrushMappingMode.Absolute, Center = new Point(0, 0), GradientOrigin = new Point(0, 0), RadiusX = 430, RadiusY = 430
        };
        window.Resources["PeshGlow"] = glow;
        var secondary = preferences.Palette switch { "pesh" => Parse("3DFF85"), "aurora" => Parse("65BFFF"), "solar" => Parse("FF7188"), _ => Parse(preferences.WaveBlend) };
        window.Resources["PeshGlowSecondary"] = new RadialGradientBrush(Color.FromArgb(10, secondary.R, secondary.G, secondary.B), Colors.Transparent) { Center = new Point(1, 1), GradientOrigin = new Point(1, 1), RadiusX = .65, RadiusY = .65 }; window.Resources["PeshGradient"] = Gradient(preferences);
        var handle = new WindowInteropHelper(window).Handle;
        if (handle != IntPtr.Zero) { int dark = light ? 0 : 1; _ = DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int)); }
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
