using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

internal static partial class Program
{
    /// The History page: friendly rows (time, first words, one status word), themed selection
    /// without a focus rectangle, list and text sharing the window, Copy and Delete side by
    /// side, no Refresh button, everything inside the window at the minimum width.
    /// PFLOW_SHOTS=<folder> writes history-{theme}-{width}.png to look at.
    static void NativeHistory()
    {
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        var now = DateTimeOffset.Now;
        Check("friendly time: today", HistoryRow.When(now, now) == "Today " + now.ToLocalTime().ToString("t"));
        Check("friendly time: yesterday", HistoryRow.When(now.AddDays(-1), now) == "Yesterday " + now.AddDays(-1).ToLocalTime().ToString("t"));
        Check("friendly time: a short date this year or with the year", HistoryRow.When(new DateTimeOffset(now.Year, 3, 4, 9, 12, 0, now.Offset), new DateTimeOffset(now.Year, 10, 22, 16, 6, 0, now.Offset)).StartsWith("Mar 4 ")
            && HistoryRow.When(new DateTimeOffset(now.Year - 1, 3, 4, 9, 12, 0, now.Offset), now).StartsWith("Mar 4, " + (now.Year - 1)));
        Check("first words cut at a word with an ellipsis", HistoryRow.Words("Once upon a time in a land far, far away where the birds would fly, there was this brown little fox that used to love to eat food.") == "Once upon a time in a land far, far away where the birds would fly,…"
            && HistoryRow.Words("Short  take\nwith breaks.") == "Short take with breaks.");
        Check("status words", HistoryRow.Status("Inserted") == "Inserted" && HistoryRow.Status(InsertionTarget.PlainOnly) == "Inserted" && HistoryRow.Status(InsertionTarget.Unchecked + " Line breaks arrived as spaces.") == "Check the field"
            && HistoryRow.Status(InsertionTarget.Unconfirmed) == "Check the field" && HistoryRow.Status(InsertionTarget.Unreachable) == "Kept" && HistoryRow.Status(InsertionTarget.SavedToHistory) == "Kept" && HistoryRow.Status(InsertionTarget.NothingLanded) == "Kept");
        const string today = "Fictional words that went in today: the lighthouse keeper counted seven blue kites over the quiet harbor, then waved goodbye to the pelicans.";
        foreach (string theme in new[] { "dark", "light" }) foreach (double width in new[] { 420.0, 900.0 }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-history-fictional-" + Guid.NewGuid().ToString("N"));
            try {
                var store = new StateStore(root); store.Preferences.Theme = theme;
                store.Add(new Transcript(Guid.NewGuid(), "Fictional older words kept in History only.", now.AddDays(-3), 4, "Fictional microphone", 7, "Notepad", null, InsertionTarget.Unreachable));
                store.Add(new Transcript(Guid.NewGuid(), "Fictional words typed yesterday into a web box.", now.AddDays(-1), 5, "Fictional microphone", 8, "Edge", null, InsertionTarget.Unconfirmed));
                store.Add(new Transcript(Guid.NewGuid(), today, now, 6, "Fictional microphone", 22, "Notepad", null, "Inserted"));
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(store, new Whisper(root), new LocalTextModel(root), hook, () => { }, () => false) { ShowActivated = false, Width = width, Height = 640 };
                try {
                    settings.Show(); settings.UpdateLayout(); Drain();
                    settings.OpenHistoryPage(); settings.UpdateLayout(); Drain();
                    string tag = $"{theme} {width:F0}: ";
                    var list = Descendants<ListBox>(settings).Single(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Past dictations");
                    var rows = list.Items.Cast<ListBoxItem>().ToList();
                    string Row(ListBoxItem item) => string.Join(" | ", Descendants<TextBlock>(item).Select(x => x.Text));
                    Check(tag + "rows are newest first with a friendly time, the status word and the first words", rows.Count == 3
                        && Row(rows[0]).StartsWith("Today ") && Row(rows[0]).Contains("·  Inserted | Fictional words that went in today: the lighthouse keeper counted seven…")
                        && Row(rows[1]).StartsWith("Yesterday ") && Row(rows[1]).Contains("·  Check the field | Fictional words typed yesterday into a web box.")
                        && Row(rows[2]).Contains("·  Kept | Fictional older words kept in History only.") && !Row(rows[2]).StartsWith("Today") && !Row(rows[2]).StartsWith("Yesterday"));
                    Check(tag + "no raw timestamp anywhere on the page", !Descendants<TextBlock>(settings).Any(x => x.Text.Contains(now.ToString()) || x.Text.Contains(now.ToString("yyyy")) && x.Text.Contains(":00")));
                    var buttons = Descendants<Button>(settings).Where(x => x.IsVisible).ToList();
                    Check(tag + "no Refresh button; Copy and Delete are themed buttons", !buttons.Any(x => x.Content as string == "Refresh History") && buttons.Count(x => x.Content as string is "Copy" or "Delete") == 2
                        && buttons.Where(x => x.Content as string is "Copy" or "Delete").All(x => x.Template == ((Style)settings.FindResource(typeof(Button))).Setters.OfType<Setter>().Single(s => s.Property == Control.TemplateProperty).Value));
                    var copy = buttons.Single(x => x.Content as string == "Copy"); var delete = buttons.Single(x => x.Content as string == "Delete");
                    var copyAt = copy.TranslatePoint(new Point(0, 0), settings); var deleteAt = delete.TranslatePoint(new Point(0, 0), settings);
                    Check(tag + "Copy and Delete sit side by side inside the window", copyAt.Y == deleteAt.Y && deleteAt.X > copyAt.X + copy.ActualWidth && deleteAt.X + delete.ActualWidth <= settings.ActualWidth
                        && deleteAt.Y + delete.ActualHeight <= settings.ActualHeight && !copy.IsEnabled && !delete.IsEnabled);
                    var text = Descendants<TextBox>(settings).Single(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Dictation text");
                    var page = Descendants<ScrollViewer>(settings).First(x => x.Content is Border);
                    rows[0].IsSelected = true; settings.UpdateLayout(); Drain();
                    if (shots != null) {
                        var content = (FrameworkElement)settings.Content;
                        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32); bitmap.Render(content);
                        var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                        Directory.CreateDirectory(shots); using var file = File.Create(Path.Combine(shots, $"history-{theme}-{width:F0}.png")); png.Save(file);
                    }
                    double widest = rows.SelectMany(r => Descendants<TextBlock>(r)).Max(t => t.ActualWidth);
                    Check(tag + $"the list and the text share the window with nothing to scroll (scrollable {page.ScrollableHeight:F0}, viewport {page.ViewportHeight:F0}, list {list.ActualHeight:F0}, text {text.ActualHeight:F0}, widest row {widest:F0} of {list.ActualWidth:F0})",
                        page.ScrollableHeight == 0 && list.ActualHeight >= 120 && text.ActualHeight >= 120 && text.ActualHeight > list.ActualHeight && widest <= list.ActualWidth);
                    Check(tag + "selecting a row shows its whole text and status and enables the buttons", text.Text == today && Descendants<TextBlock>(settings).Any(x => x.Text == "Inserted") && copy.IsEnabled && delete.IsEnabled);
                    var shell = (Border)rows[0].Template.FindName("shell", rows[0]);
                    Check(tag + "selection uses the theme with no focus rectangle", shell.Background == (Brush)settings.Resources["PeshSelection"] && rows[0].FocusVisualStyle == null && shell.CornerRadius.TopLeft == 8);
                    Clipboard.SetText("Fictional clipboard before Copy");
                    copy.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); Drain();
                    Check(tag + "Copy puts the selected text on the clipboard", Clipboard.GetText() == today);
                    delete.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); settings.UpdateLayout(); Drain();
                    Check(tag + "Delete removes the row from the store and the list and clears the text", store.History.Count == 2 && new StateStore(root).History.Count == 2 && list.Items.Count == 2 && text.Text == "" && !copy.IsEnabled);
                    // The ListBoxItem template is new; the drop-downs keep their own themed items.
                    Check(tag + "ComboBox items keep their themed template", ((Style)settings.FindResource(typeof(ComboBoxItem))).Setters.OfType<Setter>().Any(s => s.Property == Control.TemplateProperty)
                        && ((Style)settings.FindResource(typeof(ListBoxItem))).Setters.OfType<Setter>().Any(s => s.Property == FrameworkElement.FocusVisualStyleProperty && s.Value == null));
                    // Back, then History again: built fresh, so the deleted row stays gone and a new take shows.
                    store.Add(new Transcript(Guid.NewGuid(), "Fictional newest take.", now, 2, "Fictional microphone", 3, "Notepad", null, "Inserted"));
                    settings.OpenHistoryPage(); settings.UpdateLayout(); Drain();
                    var again = Descendants<ListBox>(settings).Single(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Past dictations");
                    Check(tag + "History refreshes when it opens", again.Items.Count == 3 && Row((ListBoxItem)again.Items[0]).EndsWith("Fictional newest take."));
                } finally { settings.Close(); }
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
}
