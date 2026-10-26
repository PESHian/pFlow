using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

internal static partial class Program
{
    /// The capsule: Superwhisper's pill, 62 x 34 with its glass (a near-black fill at 86%, no blur) in every theme, a 1 px outline in the accent at 65%, the
    /// waveform inside, the same size and look in every phase, never activating. PFLOW_SHOTS=<folder>
    /// writes capsule-{theme}-{palette}-{phase}.png to look at.
    static void NativeCapsule()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        CapsuleRenders();
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        foreach (string theme in new[] { "dark", "light" }) foreach (var (palette, accent) in new[] { ("pesh", "FF9DC4"), ("aurora", "4EE5B3"), ("solar", "FFBB66"), ("custom", "3366FF"), ("custom", "101010") }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-capsule-fictional-" + Guid.NewGuid().ToString("N"));
            var store = new StateStore(root); store.Preferences.Theme = theme; store.Preferences.Palette = palette; store.Preferences.Accent = accent; store.Preferences.CustomAccent = accent;
            var capsule = new Capsule(store); string tag = $"{theme}/{palette}-{accent} ";
            try {
                capsule.Set(Phase.Recording); capsule.UpdateLayout(); Drain();
                long style = Native.GetWindowLongPtr(new WindowInteropHelper(capsule).Handle, -20).ToInt64();
                Check(tag + "capsule never activates and stays off the taskbar", (style & 0x08000080) == 0x08000080 && !capsule.ShowActivated && !capsule.IsActive && !capsule.ShowInTaskbar && capsule.Topmost && capsule.IsVisible);
                var shell = capsule.Shell;
                Check(tag + "capsule is Superwhisper's pill size, 62 x 34 DIP, with a full-round corner and a 1 px outline", capsule.Width == 62 && capsule.Height == 34 && capsule.ActualWidth == 62 && capsule.ActualHeight == 34
                    && shell.ActualWidth == 62 && shell.ActualHeight == 34 && shell.CornerRadius == new CornerRadius(17) && shell.BorderThickness == new Thickness(1));
                var screenSize = new WindowInteropHelper(capsule).Handle is var hwnd && Native.GetWindowRect(hwnd, out var bounds) ? (bounds.Right - bounds.Left, bounds.Bottom - bounds.Top) : (0, 0);
                var dpiScale = VisualTreeHelper.GetDpi(capsule);
                Check(tag + $"on screen the capsule window is 62 x 34 DIP ({screenSize.Item1} x {screenSize.Item2} px at {dpiScale.PixelsPerDip * 100:F0}%)",
                    Math.Abs(screenSize.Item1 - 62 * dpiScale.DpiScaleX) <= 1 && Math.Abs(screenSize.Item2 - 34 * dpiScale.DpiScaleY) <= 1);
                Check(tag + "capsule fill is Superwhisper's glass: #121212 at 86%, no blur or effect", shell.Background is SolidColorBrush { Color: { A: 220, R: 0x12, G: 0x12, B: 0x12 }, Opacity: 1 } && shell.Effect == null && capsule.AllowsTransparency);
                var expected = (Color)ColorConverter.ConvertFromString("#" + accent);
                bool dark = PeshTheme.Luminance(expected) < PeshTheme.MinimumLuminanceOnBlack;
                Check(tag + (dark ? "outline is the accent lifted to read on black, at 65%" : "outline brush is the accent at 65%"), shell.BorderBrush is SolidColorBrush outline && outline.Color == PeshTheme.OnBlack(expected) && (dark ? outline.Color != expected && PeshTheme.Luminance(outline.Color) >= PeshTheme.MinimumLuminanceOnBlack : outline.Color == expected) && Math.Abs(outline.Opacity - .65) < .001);
                var inkColors = capsule.Wave.Color switch { SolidColorBrush s => [s.Color], LinearGradientBrush g => g.GradientStops.Select(x => x.Color).ToList(), _ => new List<Color>() };
                Check(tag + "every waveform colour reads on black", inkColors.Count > 0 && inkColors.All(c => PeshTheme.Luminance(c) >= PeshTheme.MinimumLuminanceOnBlack));
                {
                    // Superwhisper's bars: loud speech shows 6-7 separate bars, each at most 2 px wide at 100%; silence a row of dots.
                    int[] Runs(double level) {
                        capsule.Set(Phase.Idle); capsule.Set(Phase.Recording); store.Preferences.Waveform = "wave";
                        for (int i = 0; i < 40; i++) capsule.Wave.Advance(level * (.15 + .85 * Math.Pow(Math.Abs(Math.Sin(i / 2.1)), 2)), "wave", 1 / 30.0);
                        capsule.UpdateLayout(); Drain();
                        var wave = capsule.Wave; var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)wave.ActualWidth, (int)wave.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(wave);
                        var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
                        var inked = Enumerable.Range(0, bitmap.PixelWidth).Select(x => Enumerable.Range(0, bitmap.PixelHeight).Count(y => pixels[(y * bitmap.PixelWidth + x) * 4 + 3] > 128)).ToArray();
                        var runs = new List<int>(); int width = 0, tallest = 0;
                        foreach (int column in inked.Append(0)) { if (column > 0) { width++; tallest = Math.Max(tallest, column); } else if (width > 0) { runs.Add(width * 100 + tallest); width = tallest = 0; } }
                        return runs.ToArray();
                    }
                    var loud = Runs(.8); var quiet = Runs(.01);
                    Console.WriteLine($"{tag}waveform bars (width*100+height): loud [{string.Join(",", loud)}] quiet [{string.Join(",", quiet)}]");
                    Check(tag + "the waveform is 7 separate bars 2 px wide; loud speech makes some tall, silence is a row of 2 px dots",
                        loud.Length == 7 && loud.All(r => r / 100 == 2) && loud.Max(r => r % 100) >= 10 && loud.Min(r => r % 100) < loud.Max(r => r % 100)
                        && quiet.Length == 7 && quiet.All(r => r == 202));
                    capsule.Set(Phase.Recording);
                }
                Check(tag + "the waveform sits inside the outline (30 x 16)", capsule.Wave.ActualWidth == 62 - 2 - 30 && capsule.Wave.ActualHeight == 34 - 2 - 16 && capsule.Wave.TranslatePoint(new Point(0, 0), shell).X >= 16);
                var size = (capsule.ActualWidth, capsule.ActualHeight); var look = (shell.Background, shell.BorderBrush, shell.CornerRadius);
                foreach (var phase in new[] { Phase.Recording, Phase.Continuous, Phase.Processing, Phase.Inserting }) {
                    capsule.Set(phase);
                    for (int i = 0; i < 40; i++) capsule.Wave.Advance(.35 + .3 * Math.Sin(i / 3.0), store.Preferences.Waveform, 1 / 60.0);
                    capsule.UpdateLayout(); Drain();
                    Check(tag + phase + " keeps the same size and look and stays visible", (capsule.ActualWidth, capsule.ActualHeight) == size && (shell.Background, shell.BorderBrush, shell.CornerRadius) == look && capsule.IsVisible && !capsule.IsActive);
                    if (shots != null) Shoot(capsule, Path.Combine(shots, $"capsule-{theme}-{palette}{(palette == "custom" ? "-" + accent : "")}-{phase.ToString().ToLowerInvariant()}.png"), theme == "light");
                }
                capsule.Set(Phase.Idle); Drain();
                Check(tag + "idle hides the capsule", !capsule.IsVisible);
            } finally { capsule.Close(); if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }

    /// PFLOW_CAPSULE_SHOTS=<folder>: the capsule as it shows on screen, for every state, in the light theme over white
    /// and the dark theme over a dark grey (the backgrounds Superwhisper's pill was measured on), at 100% and 150%.
    /// Files: capsule-{theme}-{scale}-{state}.png.
    static void CapsuleRenders()
    {
        string? folder = Environment.GetEnvironmentVariable("PFLOW_CAPSULE_SHOTS");
        if (folder == null) return;
        Directory.CreateDirectory(folder);
        foreach (string theme in new[] { "light", "dark" }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-capsule-shots-fictional-" + Guid.NewGuid().ToString("N"));
            var store = new StateStore(root); store.Preferences.Theme = theme;
            var capsule = new Capsule(store);
            try {
                foreach (string style in new[] { "wave", "lines" })
                foreach (var (state, phase, level) in new[] { ("recording-quiet", Phase.Recording, .03), ("recording-loud", Phase.Recording, .8), ("processing", Phase.Processing, 0.0) }) {
                    if (style == "lines" && phase != Phase.Recording) continue;
                    capsule.Set(phase);
                    // A quiet take after a loud one: the scale follows the take's own peak, so start each state fresh.
                    capsule.Set(Phase.Idle); capsule.Set(phase);
                    // The capsule's own frame clock also advances the wave with the saved style: render the style asked for.
                    store.Preferences.Waveform = style;
                    // Speech-like: syllables rise and fall a few times a second (each level is held 40 ms by WaveMotion).
                    for (int i = 0; i < 90; i++) capsule.Wave.Advance(phase == Phase.Recording ? level * (.15 + .85 * Math.Pow(Math.Abs(Math.Sin(i / 2.1)), 2)) : 0, style, 1 / 30.0);
                    capsule.UpdateLayout(); Drain();
                    foreach (double scale in new[] { 1.0, 1.5 }) {
                        var content = (FrameworkElement)capsule.Content; const int margin = 12;
                        int width = (int)Math.Ceiling(content.ActualWidth) + 2 * margin, height = (int)Math.Ceiling(content.ActualHeight) + 2 * margin;
                        var scene = new DrawingVisual();
                        using (var dc = scene.RenderOpen()) {
                            dc.DrawRectangle(new SolidColorBrush(theme == "light" ? Colors.White : Color.FromRgb(32, 32, 32)), null, new Rect(0, 0, width, height));
                            dc.DrawRectangle(new VisualBrush(content) { Stretch = Stretch.None, ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(-margin, -margin, width, height),
                                ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, width, height) }, null, new Rect(0, 0, width, height));
                        }
                        var shot = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Round(width * scale), (int)Math.Round(height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32); shot.Render(scene);
                        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder(); encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(shot));
                        using var file = File.Create(Path.Combine(folder, $"capsule-{theme}-{scale * 100:F0}-{(phase == Phase.Recording ? style + "-" : "")}{state}.png")); encoder.Save(file);
                    }
                }
                Console.WriteLine($"capsule renders ({theme}): {capsule.ActualWidth} x {capsule.ActualHeight} DIP");
            } finally { capsule.Close(); if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
}
