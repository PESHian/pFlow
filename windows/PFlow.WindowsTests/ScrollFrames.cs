using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

internal static partial class Program
{
    /// A scripted wheel scroll over the Settings home page: 40 touchpad-sized events (delta -30)
    /// and 10 notches (delta -120), each followed by a layout and render pass. Prints how far the
    /// page moved and how many passes took longer than 32 ms (two frames at 60 Hz), the before/after
    /// number for the W025 "jittery scrolling" finding. Self-contained so the same file measures an
    /// older build.
    static (double SmallMoved, double NotchMoved, int Passes, int Over32, double LongestMs) ScrollFrames(bool print)
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string root = Path.Combine(Path.GetTempPath(), "pflow-scroll-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            var store = new StateStore(root); store.Preferences.Theme = "dark";
            using var hook = new KeyboardHook(_ => { }) { Enabled = false };
            var settings = new SettingsWindow(store, new Whisper(root), new LocalTextModel(root), hook, () => { }, () => false) { ShowActivated = false, Width = 460, Height = 740 };
            try {
                settings.Show(); settings.UpdateLayout(); Drain();
                var page = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel);
                // The wheel arrives over a block of text inside the page, as a pointer's would.
                var under = Descendants<TextBlock>(page).First(t => t.IsVisible);
                var costs = new List<double>();
                double Scroll(int delta, int times)
                {
                    double from = page.VerticalOffset;
                    for (int i = 0; i < times; i++) {
                        var clock = System.Diagnostics.Stopwatch.StartNew();
                        var preview = new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta) { RoutedEvent = Mouse.PreviewMouseWheelEvent, Source = under };
                        under.RaiseEvent(preview);
                        if (!preview.Handled) under.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta) { RoutedEvent = Mouse.MouseWheelEvent, Source = under });
                        page.UpdateLayout(); Drain(); costs.Add(clock.Elapsed.TotalMilliseconds);
                    }
                    return page.VerticalOffset - from;
                }
                page.ScrollToTop(); page.UpdateLayout(); Drain();
                double small = Scroll(-30, 40), notch = Scroll(-120, 10);
                var result = (small, notch, costs.Count, costs.Count(x => x > 32), costs.Max());
                if (print) Console.WriteLine($"SCROLL-FRAMES small40={small:F0}px notch10={notch:F0}px passes={costs.Count} over32ms={result.Item4} longest={costs.Max():F1}ms scrollable={page.ScrollableHeight:F0}");
                return result;
            } finally { settings.Close(); }
        } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
