using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PFlow.Core;
using PFlow.Windows;

internal static partial class Program
{
    static bool scrollFramesOnly;

    /// --scroll-frames: the Settings home page on the real desktop, scrolled by a scripted wheel
    /// (10 notches, one every 100 ms) and a touchpad-style stream (60 events of delta -20, one per
    /// timer tick of the default Windows resolution, about 16 ms), each followed by 500 ms of rest, after one warm-up pass over the page. Every rendered frame is timed and the page's offset at
    /// that frame recorded: frame intervals over 16.7 and 33.4 ms, the longest, and the largest jump
    /// of the page between two frames. Uses only types every build since 0.1.20 has, so the same file
    /// measures an older tree for the before numbers.
    static async Task ScrollFramesRun()
    {
        string directory = Path.Combine(root, "scroll-frames-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        try {
            var store = new StateStore(directory); store.Preferences.Theme = "dark";
            using var hook = new KeyboardHook(_ => { }) { Enabled = false };
            var settings = new SettingsWindow(store, new Whisper(directory), new LocalTextModel(directory), hook, () => { }, () => false) { Width = 460, Height = 740, Left = 40, Top = 20, WindowStartupLocation = WindowStartupLocation.Manual };
            settings.Show(); await Task.Delay(1500);
            ScrollViewer page = null!;
            foreach (var viewer in All<ScrollViewer>(settings)) if (viewer.Content is StackPanel) { page = viewer; break; }
            TextBlock under = null!;
            foreach (var text in All<TextBlock>(page)) if (text.IsVisible) { under = text; break; }
            var clock = Stopwatch.StartNew();
            var frames = new List<(double Ms, double Offset)>();
            void Frame(object? sender, EventArgs e) => frames.Add((clock.Elapsed.TotalMilliseconds, page.VerticalOffset));
            // Warm-up: the whole page once down and up, so both phases scroll content that has been drawn before.
            for (double y = 0; y <= page.ScrollableHeight; y += 120) { page.ScrollToVerticalOffset(y); await Task.Delay(30); }
            page.ScrollToTop(); await Task.Delay(800);
            CompositionTarget.Rendering += Frame;
            async Task<string> Phase(string name, int delta, int count, int everyMs)
            {
                page.ScrollToTop(); await Task.Delay(600);
                frames.Clear(); double start = clock.Elapsed.TotalMilliseconds, from = page.VerticalOffset;
                for (int i = 0; i < count; i++) {
                    double due = start + i * everyMs;
                    while (clock.Elapsed.TotalMilliseconds < due) await Task.Delay(1);
                    var wheel = new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta) { RoutedEvent = Mouse.PreviewMouseWheelEvent, Source = under };
                    under.RaiseEvent(wheel);
                    if (!wheel.Handled) under.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta) { RoutedEvent = Mouse.MouseWheelEvent, Source = under });
                }
                double sentMs = clock.Elapsed.TotalMilliseconds - start;
                await Task.Delay(500);
                var taken = frames.Where(f => f.Ms >= start).ToList();
                var gaps = taken.Zip(taken.Skip(1), (a, b) => b.Ms - a.Ms).ToList();
                Console.WriteLine($"SCROLL-GAPS {name}: " + string.Join(" ", gaps.Select(g => g.ToString("F0"))));
                var jumps = taken.Zip(taken.Skip(1), (a, b) => Math.Abs(b.Offset - a.Offset)).ToList();
                return $"SCROLL-FRAMES {name}: events={count}x{delta} sent over {sentMs:F0}ms moved={page.VerticalOffset - from:F0}px frames={taken.Count} over16.7ms={gaps.Count(g => g > 16.7)} over33.4ms={gaps.Count(g => g > 33.4)} longest={(gaps.Count > 0 ? gaps.Max() : 0):F1}ms moving-frames={jumps.Count(j => j > 0.01)} largest-jump={(jumps.Count > 0 ? jumps.Max() : 0):F1}px";
            }
            // Each phase twice, alternating, so neither order nor a first pass decides the numbers.
            foreach (string round in new[] { "1", "2" }) {
                Console.WriteLine(await Phase("wheel-" + round, -120, 10, 100));
                Console.WriteLine(await Phase("touchpad-" + round, -20, 60, 10));
            }
            CompositionTarget.Rendering -= Frame;
            settings.Close();
        } finally {
            try { Directory.Delete(directory, true); } catch (IOException) { }
        }
    }
    static IEnumerable<T> All<T>(DependencyObject parent) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match) yield return match;
            foreach (var inner in All<T>(child)) yield return inner;
        }
    }
}
