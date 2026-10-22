using System.Runtime.InteropServices;
using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Media;

internal static partial class Program
{
    static void NativeControls()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        NativePreviewCard();
        NativePromptCard();
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
                var headings = Descendants<TextBlock>(settings).Where(x => x.FontFamily.Source == "Consolas" && x.FontSize == 10).Select(x => x.Text).ToList();
                Check("Live text has its own section right after Shortcut", headings.Count(x => x == "LIVE TEXT") == 1 && headings.IndexOf("LIVE TEXT") == headings.IndexOf("SHORTCUT") + 1);
                var liveChoices = Descendants<RadioButton>(settings).Where(x => x.GroupName == "LiveText").ToList();
                Check("Settings shows both Live text choices, no drop-down", liveChoices.Count == 2 && liveChoices.Select(x => (string)x.Tag).SequenceEqual(LiveTextModes.All.Select(c => c.Id))
                    && liveChoices.All(x => x.IsVisible) && !Descendants<ComboBox>(settings).Any(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Live text"));
                Check("the saved Live text choice is the one selected", liveChoices.Single(x => x.IsChecked == true).Tag as string == LiveTextModes.Off);
                liveChoices[1].IsChecked = true; Drain();
                Check("picking Type in the current app saves it for the next take", new StateStore(root).Preferences.LiveTextMode == LiveTextModes.TypeInApp && liveChoices.Count(x => x.IsChecked == true) == 1);
                liveChoices[0].IsChecked = true; Drain();
                Check("picking Off saves it again", new StateStore(root).Preferences.LiveTextMode == LiveTextModes.Off);
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
                foreach (string name in new[] { "Speech language", "Activation key" })
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

    /// The live text card: one height for the whole take, readable in both
    /// looks, never activating. PFLOW_SHOTS=<folder> also writes PNGs to look at.
    static void NativePreviewCard()
    {
        double Luminance(Color color) {
            double Channel(byte x) { double c = x / 255.0; return c <= .04045 ? c / 12.92 : Math.Pow((c + .055) / 1.055, 2.4); }
            return .2126 * Channel(color.R) + .7152 * Channel(color.G) + .0722 * Channel(color.B);
        }
        double Contrast(Brush a, Brush b) { double x = Luminance(((SolidColorBrush)a).Color), y = Luminance(((SolidColorBrush)b).Color); return (Math.Max(x,y)+.05)/(Math.Min(x,y)+.05); }
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        const string story = "The lighthouse keeper counted seven blue kites over the quiet harbor, then waved goodbye to the pelicans and walked home along the sea wall, where the orchard lanterns glowed.";
        foreach (string theme in new[] { "dark", "light" }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-preview-fictional-" + Guid.NewGuid().ToString("N"));
            var store = new StateStore(root); store.Preferences.Theme = theme;
            var preview = new LivePreview(store);
            try {
                preview.Begin(); preview.Show(); preview.UpdateLayout(); Drain();
                double empty = preview.ActualHeight;
                var style = Native.GetWindowLongPtr(new WindowInteropHelper(preview).Handle, -20).ToInt64();
                Check($"{theme} card never activates and lets clicks through", (style & 0x08000020) == 0x08000020 && !preview.Focusable && !preview.ShowActivated && !preview.IsActive);
                Check($"{theme} card says Listening before any words", preview.Caption == "Listening" && preview.Shown == "" && preview.Note == null);
                preview.ShowText("Seven"); Drain();
                preview.ShowText(story); Drain();
                Check($"{theme} card keeps one height as words arrive", preview.ActualHeight == empty && preview.LinesHeight == preview.WordsLineHeight * 4 && preview.LinesHeight % preview.WordsLineHeight == 0 && preview.Shown.EndsWith("glowed."));
                Check($"{theme} card words and caption are readable on the card", Contrast(preview.WordsBrush, preview.Card is Border b ? b.Background : Brushes.Black) >= 7 && Contrast(preview.CaptionBrush, ((Border)preview.Card).Background) >= 4.5);
                if (shots != null) Shoot(preview, Path.Combine(shots, $"preview-listening-{theme}.png"), theme == "light");
                preview.SetNote("Stopped: cursor moved"); Drain();
                Check($"{theme} note replaces the caption without resizing", preview.Caption == "Stopped: cursor moved" && preview.ActualHeight == empty);
                if (shots != null) Shoot(preview, Path.Combine(shots, $"preview-stopped-{theme}.png"), theme == "light");
                preview.Finishing(); Drain();
                Check($"{theme} finishing shows in the caption", preview.Caption == "Finishing…");
                if (shots != null) Shoot(preview, Path.Combine(shots, $"preview-finishing-{theme}.png"), theme == "light");
                preview.Clear();
                Check($"{theme} a new take starts clean", preview.Caption == "Listening" && preview.Shown == "" && !preview.IsVisible);
            } finally { preview.Close(); if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }

    /// The "couldn't type this" card and the start notice: shown without taking
    /// focus, readable in both looks, a touch-sized Copy button that is the only
    /// thing that writes the clipboard. PFLOW_SHOTS=<folder> also writes PNGs.
    static void words_focus(PromptCard card) { if (card.Card is Border b && b.Child is StackPanel stack) stack.Children.OfType<TextBox>().First().Focus(); }
    static void NativePromptCard()
    {
        double Luminance(Color color) {
            double Channel(byte x) { double c = x / 255.0; return c <= .04045 ? c / 12.92 : Math.Pow((c + .055) / 1.055, 2.4); }
            return .2126 * Channel(color.R) + .7152 * Channel(color.G) + .0722 * Channel(color.B);
        }
        double Contrast(Brush a, Brush b) { double x = Luminance(((SolidColorBrush)a).Color), y = Luminance(((SolidColorBrush)b).Color); return (Math.Max(x,y)+.05)/(Math.Min(x,y)+.05); }
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        const string words = "The lighthouse keeper counted seven blue kites over the quiet harbor, then waved goodbye to the pelicans.\nSecond fictional line.";
        foreach (string theme in new[] { "dark", "light" }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-prompt-fictional-" + Guid.NewGuid().ToString("N"));
            var store = new StateStore(root); store.Preferences.Theme = theme;
            var anchor = new Window { Width = 120, Height = 40, WindowStyle = WindowStyle.None, ShowInTaskbar = false, ShowActivated = false, Left = 300, Top = 300 };
            var card = new PromptCard(store);
            try {
                anchor.Show(); Drain();
                uint clipboard = Native.GetClipboardSequenceNumber();
                card.ShowWords(words, "Focus changed. Your text is in History.", new WindowInteropHelper(anchor).Handle); Drain();
                Check($"{theme} card shows without taking focus", card.IsVisible && !card.ShowActivated && !card.IsActive);
                Check($"{theme} card shows the title, the plain reason and the exact words to copy", card.Title_ == InsertionPrompt.Title && card.Reason == "You switched to another window before pFlow could type." && card.Words == words && card.WordsShown && card.CopyShown);
                var face = card.Card is Border b ? b.Background : Brushes.Black;
                Check($"{theme} card text is readable: title, reason, words and the Copy label", Contrast(card.TitleBrush, face) >= 7 && Contrast(card.ReasonBrush, face) >= 4.5
                    && Contrast(card.WordsBrush, card.WordsBackground) >= 7 && Contrast(card.CopyBrush, card.CopyBackground) >= 4.5);
                Check($"{theme} Copy is touch-sized (44 px or more)", card.CopyHeight >= 44);
                Check($"{theme} showing the card never touches the clipboard", Native.GetClipboardSequenceNumber() == clipboard);
                if (shots != null) Shoot(card, Path.Combine(shots, $"prompt-{theme}.png"), theme == "light");
                var copy = card.Card is Border border && border.Child is StackPanel stack ? stack.Children.OfType<StackPanel>().Last().Children.OfType<Button>().First() : null;
                copy!.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); Drain();
                Check($"{theme} Copy puts exactly the words on the clipboard and says Copied", card.Copies == 1 && Native.GetClipboardSequenceNumber() != clipboard && Clipboard.GetText() == words && card.CopyLabel == InsertionPrompt.Copied);
                // The words box focused inside pFlow's own window: a take must refuse, never target whatever hides behind the card.
                // The cursor in the card: a take must refuse, never target whatever hides behind the card. Only pFlow's floating
                // windows are refused; a window like Settings (not registered) with its own editable fields is not. A process started
                // by a scheduled task cannot bring its window to the front, so the foreground window is supplied.
                InsertionTarget.RefusedWindows.Add(card.Handle); words_focus(card); Drain();
                string refusal = ""; try { var got = InsertionTarget.Capture(() => card.Handle); refusal = "captured " + got.Kind; } catch (InvalidOperationException error) { refusal = error.Message; }
                Check($"{theme} dictating with the cursor in the words card is refused", refusal == InsertionTarget.OwnWindow);
                string settingsLike = ""; try { InsertionTarget.Capture(() => new WindowInteropHelper(anchor).Handle); settingsLike = "captured"; } catch (InvalidOperationException error) { settingsLike = error.Message; }
                Check($"{theme} one of pFlow's own windows that is not a floating card (Settings and its editable fields) is not refused", settingsLike != InsertionTarget.OwnWindow);
                Check($"{theme} the focused-element guard refuses the card's window and no other", InsertionTarget.Refused(card.Handle) && !InsertionTarget.Refused(new WindowInteropHelper(anchor).Handle) && !InsertionTarget.Refused(IntPtr.Zero));
                // Auto-hide: a maximized window (caption, frame, rect beyond the monitor) is never full screen; a borderless window covering the monitor exactly is.
                var maximized = new Window { Title = "Fictional maximized", ShowActivated = false, ShowInTaskbar = false };
                var bounds = System.Windows.Forms.Screen.PrimaryScreen!.Bounds; var dpi = VisualTreeHelper.GetDpi(card);
                var borderless = new Window { Title = "Fictional full screen", WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowActivated = false, ShowInTaskbar = false,
                    Left = bounds.Left / dpi.DpiScaleX, Top = bounds.Top / dpi.DpiScaleY, Width = bounds.Width / dpi.DpiScaleX, Height = bounds.Height / dpi.DpiScaleY };
                try {
                    // One at a time: while the borderless window covers the screen, Windows itself reports a full-screen app.
                    maximized.Show(); maximized.WindowState = WindowState.Maximized; Drain();
                    IntPtr maximizedHandle = new WindowInteropHelper(maximized).Handle;
                    Native.GetWindowRect(maximizedHandle, out var m);
                    Console.WriteLine($"FULLSCREEN {theme}: maximized {m.Left},{m.Top},{m.Right},{m.Bottom} style 0x{Native.GetWindowLongPtr(maximizedHandle, -16).ToInt64():x} monitor {bounds}");
                    Check($"{theme} a maximized window in front does not count as full screen", !PromptCard.FullScreenInFront(maximizedHandle));
                    maximized.Close(); Drain();
                    borderless.Show(); Drain();
                    IntPtr borderlessHandle = new WindowInteropHelper(borderless).Handle;
                    Native.GetWindowRect(borderlessHandle, out var f);
                    Console.WriteLine($"FULLSCREEN {theme}: borderless {f.Left},{f.Top},{f.Right},{f.Bottom} style 0x{Native.GetWindowLongPtr(borderlessHandle, -16).ToInt64():x}");
                    Check($"{theme} a borderless window covering the monitor exactly counts as full screen", PromptCard.FullScreenInFront(borderlessHandle));
                } finally { if (maximized.IsVisible) maximized.Close(); borderless.Close(); Drain(); }
                card.Dismiss(); Drain();
                Check($"{theme} close hides the card and lets the words go", !card.IsVisible && card.Words == "" && card.Reason == "");
                card.ShowNotice(StartNotice.Body("Right Ctrl"), StartNotice.Settings, TimeSpan.Zero); Drain();
                Check($"{theme} the start notice says where pFlow is and how to dictate, with no words box and no Copy", card.IsVisible && card.Title_ == StartNotice.Title
                    && card.Reason.Contains("Hold Right Ctrl") && !card.WordsShown && !card.CopyShown);
                if (shots != null) Shoot(card, Path.Combine(shots, $"notice-{theme}.png"), theme == "light");
                card.Dismiss(); Drain();
            } finally { card.Close(); anchor.Close(); try { Clipboard.Clear(); } catch { } if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }

    static void Shoot(Window window, string path, bool light)
    {
        var content = (FrameworkElement)window.Content;
        const int margin = 16, scale = 2;
        int width = (int)Math.Ceiling(content.ActualWidth) + 2 * margin, height = (int)Math.Ceiling(content.ActualHeight) + 2 * margin;
        var scene = new DrawingVisual();
        using (var dc = scene.RenderOpen()) {
            dc.DrawRectangle(new SolidColorBrush(light ? Color.FromRgb(0xF0, 0xF0, 0xF0) : Color.FromRgb(0x20, 0x20, 0x24)), null, new Rect(0, 0, width, height));
            // The card's own coordinates, with room for its shadow: the drop shadow widens the visual's bounds, so a plain brush would shift and clip it.
            dc.DrawRectangle(new VisualBrush(content) { Stretch = Stretch.None, ViewboxUnits = BrushMappingMode.Absolute,
                Viewbox = new Rect(-margin, -margin, width, height), ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, width, height) }, null, new Rect(0, 0, width, height));
        }
        var shot = new System.Windows.Media.Imaging.RenderTargetBitmap(width * scale, height * scale, 96 * scale, 96 * scale, PixelFormats.Pbgra32); shot.Render(scene);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder(); encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(shot));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var file = File.Create(path); encoder.Save(file);
    }
}
