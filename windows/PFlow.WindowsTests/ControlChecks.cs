using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Media;

internal static partial class Program
{
    static void NativeControls()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        double Luminance(Color color) {
            double Channel(byte x) { double c = x / 255.0; return c <= .04045 ? c / 12.92 : Math.Pow((c + .055) / 1.055, 2.4); }
            return .2126 * Channel(color.R) + .7152 * Channel(color.G) + .0722 * Channel(color.B);
        }
        double Contrast(Brush a, Brush b) { double x = Luminance(((SolidColorBrush)a).Color), y = Luminance(((SolidColorBrush)b).Color); return (Math.Max(x,y)+.05)/(Math.Min(x,y)+.05); }
        foreach (string theme in new[] { "dark", "light", "system" }) {
            foreach (var (palette, accent) in new[] { ("pesh","FF9DC4"), ("aurora","4EE5B3"), ("solar","FFBB66"), ("custom","000000"), ("custom","FFFFFF"), ("custom","333333") }) {
                var preferences = new Preferences { Theme = theme, Palette = palette, Accent = accent, CustomAccent = accent };
                var box = new CheckBox { Content = "Fictional setting", IsChecked = false };
                var window = new Window { Width = 380, Height = 110, Content = box };
                window.Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(new Uri("/pFlow;component/SettingsStyles.xaml", UriKind.Relative)));
                PeshTheme.Apply(window, preferences);
                try {
                    window.Show(); window.UpdateLayout(); Drain();
                    var toggle = (IToggleProvider)UIElementAutomationPeer.CreatePeerForElement(box).GetPattern(PatternInterface.Toggle);
                    var thumb = (System.Windows.Shapes.Ellipse)box.Template.FindName("thumb", box);
                    var track = (Border)box.Template.FindName("track", box);
                    var state = (TextBlock)box.Template.FindName("state", box);
                    Check($"{theme}/{accent} Off has readable label, outline and left thumb", state.Text == "Off" && thumb.HorizontalAlignment == HorizontalAlignment.Left && Contrast(thumb.Fill,track.Background) >= 3 && Contrast(track.BorderBrush,window.Background) >= 3 && Contrast(state.Foreground,window.Background) >= 4.5);
                    toggle.Toggle(); Drain();
                    Check($"{theme}/{accent} On uses readable accent ink and right thumb", box.IsChecked == true && state.Text == "On" && thumb.HorizontalAlignment == HorizontalAlignment.Right && Contrast(thumb.Fill,track.Background) >= 4.5);
                    toggle.Toggle(); Drain();
                    Check($"{theme}/{accent} second toggle returns to Off", box.IsChecked == false && state.Text == "Off" && thumb.HorizontalAlignment == HorizontalAlignment.Left);
                    box.IsEnabled = false; Drain();
                    Check($"{theme}/{accent} disabled setting retains its visible state", state.Text == "Off" && state.IsVisible && track.IsVisible);
                } finally { window.Close(); }
            }
        }
        string root = Path.Combine(Path.GetTempPath(), "pflow-controls-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            var store = new StateStore(root);
            using var hook = new KeyboardHook(_ => {}) { Enabled = false };
            var settings = new SettingsWindow(store,new Whisper(root),new LocalTextModel(root),hook,()=>{},()=>false);
            try {
                settings.Show(); settings.UpdateLayout(); Drain();
                var sound = Descendants<CheckBox>(settings).Single(x => x.Content as string == "Quiet start and stop sounds");
                bool previous = store.Preferences.Sounds;
                var toggle = (IToggleProvider)UIElementAutomationPeer.CreatePeerForElement(sound).GetPattern(PatternInterface.Toggle);
                toggle.Toggle(); Drain();
                Check("Settings toggle saves its visible value for relaunch", sound.IsChecked == !previous && new StateStore(root).Preferences.Sounds == !previous);
                toggle.Toggle(); Drain();
                Check("Settings toggle saves the return state", sound.IsChecked == previous && new StateStore(root).Preferences.Sounds == previous);
                // A closed drop-down shows the chosen item's label, never its raw data ("[en, English]").
                string Shown(ComboBox box) => string.Join("|", Descendants<TextBlock>(box).Select(x => x.Text));
                string Label(ComboBox box) => string.IsNullOrEmpty(box.DisplayMemberPath) ? box.SelectedItem!.ToString()!
                    : box.SelectedItem!.GetType().GetProperty(box.DisplayMemberPath)!.GetValue(box.SelectedItem)!.ToString()!;
                var boxes = Descendants<ComboBox>(settings).Where(x => x.SelectedItem != null).ToList();
                foreach (string name in new[] { "Speech language", "Activation key", "Live text" })
                    Check($"closed {name} drop-down shows its label", boxes.SingleOrDefault(x => System.Windows.Automation.AutomationProperties.GetName(x) == name) is { } box && Shown(box) == Label(box) && !Shown(box).Contains('['));
                Check("Speech language shows English before it is opened", Shown(boxes.Single(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Speech language")) == "English");
                foreach (var box in boxes) Check($"closed drop-down '{System.Windows.Automation.AutomationProperties.GetName(box)}' shows '{Label(box)}'", Shown(box) == Label(box));
                Check("timing readout is present without starting microphone", Descendants<TextBlock>(settings).Any(x => x.Text == ProcessingTimes.Read(root)) && !hook.Enabled);
            } finally { settings.Close(); }
            Check("missing timing record gives clear next-use message", ProcessingTimes.Read(root).Contains("next dictation"));
            store.Write("last-processing-times.json",new { totalAfterReleaseMs=8650,recognitionMs=600,cleanupMs=8000,insertionMs=20,transcript="Fictional private marker never shown" });
            string timing = ProcessingTimes.Read(root);
            Check("readout separates speech and AI without exposing transcript", timing.Contains("Speech:") && timing.Contains("AI cleanup:") && timing.Contains("Insertion:") && !timing.Contains("marker"));
            File.WriteAllText(Path.Combine(root,"last-processing-times.json"),"[]");
            Check("invalid timing record cannot break Settings", ProcessingTimes.Read(root) == "Processing time is unavailable.");
            File.WriteAllText(Path.Combine(root,"last-processing-times.json"),new string('x',16385));
            Check("oversized timing record is bounded", ProcessingTimes.Read(root) == "Processing time is unavailable.");
        } finally { Directory.Delete(root,true); }
    }
}
