using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

internal static partial class Program
{
    /// The capsule: 96 x 26, solid black in every theme, a 1 px outline in the accent at 65%, the
    /// waveform inside, the same size and look in every phase, never activating. PFLOW_SHOTS=<folder>
    /// writes capsule-{theme}-{palette}-{phase}.png to look at.
    static void NativeCapsule()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        foreach (string theme in new[] { "dark", "light" }) foreach (var (palette, accent) in new[] { ("pesh", "FF9DC4"), ("aurora", "4EE5B3"), ("solar", "FFBB66"), ("custom", "3366FF") }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-capsule-fictional-" + Guid.NewGuid().ToString("N"));
            var store = new StateStore(root); store.Preferences.Theme = theme; store.Preferences.Palette = palette; store.Preferences.Accent = accent; store.Preferences.CustomAccent = accent;
            var capsule = new Capsule(store); string tag = $"{theme}/{palette} ";
            try {
                capsule.Set(Phase.Recording); capsule.UpdateLayout(); Drain();
                long style = Native.GetWindowLongPtr(new WindowInteropHelper(capsule).Handle, -20).ToInt64();
                Check(tag + "capsule never activates and stays off the taskbar", (style & 0x08000080) == 0x08000080 && !capsule.ShowActivated && !capsule.IsActive && !capsule.ShowInTaskbar && capsule.Topmost && capsule.IsVisible);
                var shell = capsule.Shell;
                Check(tag + "capsule is 96 x 26 with a full-round corner and a 1 px outline", capsule.Width == 96 && capsule.Height == 26 && capsule.ActualWidth == 96 && capsule.ActualHeight == 26 && shell.ActualWidth == 96 && shell.ActualHeight == 26
                    && shell.CornerRadius == new CornerRadius(13) && shell.BorderThickness == new Thickness(1));
                Check(tag + "capsule fill is solid black, no acrylic or blur", shell.Background is SolidColorBrush { Color: { A: 255, R: 0, G: 0, B: 0 }, Opacity: 1 } && shell.Effect == null && capsule.AllowsTransparency);
                var expected = (Color)ColorConverter.ConvertFromString("#" + accent);
                Check(tag + "outline brush is the accent at 65%", shell.BorderBrush is SolidColorBrush outline && outline.Color == expected && Math.Abs(outline.Opacity - .65) < .001);
                Check(tag + "the waveform sits inside the outline", capsule.Wave.ActualWidth > 0 && capsule.Wave.ActualWidth <= 96 - 2 - 16 && capsule.Wave.ActualHeight <= 26 - 2 - 8 && capsule.Wave.TranslatePoint(new Point(0, 0), shell).X >= 9);
                var size = (capsule.ActualWidth, capsule.ActualHeight); var look = (shell.Background, shell.BorderBrush, shell.CornerRadius);
                foreach (var phase in new[] { Phase.Recording, Phase.Continuous, Phase.Processing, Phase.Inserting }) {
                    capsule.Set(phase);
                    for (int i = 0; i < 40; i++) capsule.Wave.Advance(.35 + .3 * Math.Sin(i / 3.0), store.Preferences.Waveform, 1 / 60.0);
                    capsule.UpdateLayout(); Drain();
                    Check(tag + phase + " keeps the same size and look and stays visible", (capsule.ActualWidth, capsule.ActualHeight) == size && (shell.Background, shell.BorderBrush, shell.CornerRadius) == look && capsule.IsVisible && !capsule.IsActive);
                    if (shots != null) Shoot(capsule, Path.Combine(shots, $"capsule-{theme}-{palette}-{phase.ToString().ToLowerInvariant()}.png"), theme == "light");
                }
                capsule.Set(Phase.Idle); Drain();
                Check(tag + "idle hides the capsule", !capsule.IsVisible);
            } finally { capsule.Close(); if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
}
