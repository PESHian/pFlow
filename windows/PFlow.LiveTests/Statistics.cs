using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PFlow.Core;
using PFlow.Windows;

internal static partial class Program
{
    static async Task StatisticsPage()
    {
        string directory = Path.Combine(root, "statistics-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        using var keyboard = new KeyboardHook(_ => {}) { Enabled = false };
        var store = new StateStore(directory); store.Preferences.Theme = "dark"; store.Preferences.Palette = "pesh"; store.SavePreferences();
        var today = DateTime.Today;
        Transcript Item(DateTime day, int words, double? seconds, string? app, string? id) => new(Guid.NewGuid(), "Fictional bicycle note.", new DateTimeOffset(DateTime.SpecifyKind(day.AddHours(12), DateTimeKind.Local)), seconds, null, words, app, id, "Inserted");
        store.Add(Item(today.AddDays(-1), 3600, 1800, "Notepad", "notepad"));
        store.Add(Item(today.AddDays(-2), 2400, 1200, "Edge", "msedge"));
        store.Add(Item(today.AddDays(-2), 1000, null, null, null));
        var originalHistory = File.ReadAllBytes(Path.Combine(directory, "history.json"));
        var originalSettings = File.ReadAllBytes(Path.Combine(directory, "settings.json"));
        SettingsWindow Make() => new(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => {}, () => false) { Title = "pFlow fictional usage statistics", ShowActivated = false };
        var window = Make();
        async Task Invoke(string caption) {
            var button = Descendants<Button>(window).Single(x => AutomationProperties.GetName(x) == caption || x.Content as string == caption);
            var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(button);
            ((System.Windows.Automation.Provider.IInvokeProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(80); window.UpdateLayout();
        }
        TextBlock Text(string text) => Descendants<TextBlock>(window).First(x => x.Text == text);
        Grid Table(string name) => Descendants<Grid>(window).Single(x => AutomationProperties.GetName(x) == name);
        try {
            window.Show(); await Task.Delay(150); await Invoke("Usage statistics");
            var labels = new[] { "Words dictated", "Dictations", "Time tracked", "WPM tracked" };
            var positions = labels.Select(x => Text(x).TransformToAncestor(window).Transform(new Point())).ToArray();
            Check("four summary captions share one row", positions.All(x => Math.Abs(x.Y - positions[0].Y) < 1) && positions.Zip(positions.Skip(1)).All(x => x.First.X < x.Second.X));
            var names = Descendants<TextBlock>(window).Select(AutomationProperties.GetName).ToArray();
            Check("summary uses saved totals and timed-only pace", names.Contains("Words dictated: 7,000") && names.Contains("Dictations: 3") && names.Contains("Time tracked: 50m 0s") && names.Contains("WPM tracked: 120"));
            Check("legacy timing caveat explains the denominator", Text("Speaking pace uses 6,000 words with recorded timing. Earlier word totals have no reliable timing.") != null);
            var chart = Descendants<UsageChart>(window).Single();
            var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(chart);
            Check("chart exposes seven accessible daily totals", peer.GetName().Count(x => x == ':') == 7 && peer.GetName().Contains("3,600 words") && peer.GetName().Contains("3,400 words") && peer.GetName().Contains("0 words"));
            Check("chart uses a vertical palette gradient", chart.Ink is LinearGradientBrush gradient && gradient.GradientStops.Count == 6);
            Check("daily table includes active dates and four columns", Table("Daily usage").RowDefinitions.Count == 3 && Table("Daily usage").ColumnDefinitions.Count == 4 && Descendants<TextBlock>(Table("Daily usage")).Any(x => x.Text == today.AddDays(-1).ToString("MMM d, yyyy")));
            Check("legacy app has missing time and pace dashes", Descendants<TextBlock>(Table("Usage by app")).Count(x => x.Text == "—") == 2 && Descendants<TextBlock>(Table("Usage by app")).Any(x => x.Text == "Earlier activity"));
            foreach (double width in new[] { 420.0, 700 }) {
                window.Width = width; window.UpdateLayout(); await Task.Delay(40);
                var daily = Table("Daily usage"); var apps = Table("Usage by app");
                double Edge(Grid table, int column) => Descendants<TextBlock>(table).First(x => Grid.GetRow(x) == 0 && Grid.GetColumn(x) == column).TransformToAncestor(window).Transform(new Point(Descendants<TextBlock>(table).First(x => Grid.GetRow(x) == 0 && Grid.GetColumn(x) == column).ActualWidth, 0)).X;
                Check($"daily and app numeric columns align at width {width}", Enumerable.Range(1, 3).All(x => Math.Abs(Edge(daily, x) - Edge(apps, x)) < 1));
                Check($"statistics fit the client width {width}", chart.ActualWidth > 260 && Descendants<ScrollViewer>(window).All(x => x.ScrollableWidth == 0));
            }
            window.Width = 460; window.UpdateLayout();
            var image = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32); image.Render(window);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using (var stream = File.Create(Path.Combine(root, "statistics-fictional-dark.png"))) encoder.Save(stream);
            Check("opening statistics never changes saved history or preferences", originalHistory.SequenceEqual(File.ReadAllBytes(Path.Combine(directory, "history.json"))) && originalSettings.SequenceEqual(File.ReadAllBytes(Path.Combine(directory, "settings.json"))));
            await Invoke("Back"); store.Add(Item(today, 25, 10, "Bicycle editor with a very long fictional name 李", "fictional")); await Invoke("Usage statistics");
            Check("returning to statistics picks up new dictations", Descendants<TextBlock>(window).Any(x => AutomationProperties.GetName(x) == "Words dictated: 7,025") && Table("Daily usage").RowDefinitions.Count == 4);
            window.Close(); store.Preferences.Theme = "light"; window = Make(); window.Show(); await Task.Delay(100); await Invoke("Usage statistics");
            chart = Descendants<UsageChart>(window).Single();
            Check("statistics labels follow the light theme", ((SolidColorBrush)chart.LabelInk).Color == ((SolidColorBrush)window.Resources["PeshMuted"]).Color && Contrast(((SolidColorBrush)chart.LabelInk).Color, ((SolidColorBrush)window.Resources["PeshBackground"]).Color) >= 4.5);
            window.Close(); store.History.Clear(); window = Make(); window.Show(); await Task.Delay(100); await Invoke("Usage statistics");
            Check("empty page has real zero totals and no fake timing", Descendants<TextBlock>(window).Any(x => AutomationProperties.GetName(x) == "Words dictated: 0") && Descendants<TextBlock>(window).Any(x => AutomationProperties.GetName(x) == "WPM tracked: —") && Descendants<TextBlock>(window).Count(x => x.Text == "No dictations yet.") == 2);
            Check("duration formatting matches seconds minutes and hours", SettingsWindow.UsageTime(new(1, 1, 43.9)) == "43s" && SettingsWindow.UsageTime(new(1, 1, 1800)) == "30m 0s" && SettingsWindow.UsageTime(new(1, 1, 3700)) == "1h 1m" && SettingsWindow.UsageTime(new(1, 1, 0)) == "—");
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
}
