using System.Text.Json;
using Microsoft.Win32;

namespace PFlow.Windows;

internal sealed partial class SettingsWindow : Window
{
    readonly StateStore store;
    readonly Whisper whisper;
    readonly LocalTextModel textModel;
    readonly KeyboardHook keyboard;
    readonly Action appearance;
    readonly Func<bool> busy;
    readonly Action? checkUpdates;
    CancellationTokenSource? download;
    readonly TextBlock processingTime = Text("Processing time appears here after your next dictation.");
    readonly ContentControl page = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    UIElement home = null!;
    readonly Dictionary<string, UIElement> navigationPages = [];
    readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 1, 0, 1) };
    public SettingsWindow(StateStore store, Whisper whisper, LocalTextModel textModel, KeyboardHook keyboard, Action appearance, Func<bool> busy, Action? checkUpdates = null)
    {
        this.store = store; this.whisper = whisper; this.keyboard = keyboard; this.appearance = appearance; this.busy = busy;
        this.textModel = textModel; this.checkUpdates = checkUpdates;
        Title = "pFlow by Pesh"; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var area = SystemParameters.WorkArea; double availableWidth = Math.Max(240, area.Width - 32), availableHeight = Math.Max(240, area.Height - 32);
        Width = Math.Min(460, availableWidth); Height = Math.Min(740, availableHeight); MinWidth = Math.Min(420, availableWidth); MinHeight = Math.Min(420, availableHeight);
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/pFlow;component/Assets/Pesh.ico"));
        FontFamily = new FontFamily("Segoe UI"); FontSize = 13; UseLayoutRounding = true;
        Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(new Uri("/pFlow;component/SettingsStyles.xaml", UriKind.Relative)));
        var canvas = new Grid(); canvas.SetResourceReference(Grid.BackgroundProperty, "PeshBackground"); var glow = new Border { IsHitTestVisible = false }; glow.SetResourceReference(Border.BackgroundProperty, "PeshGlow");
        var blend = new Border { IsHitTestVisible = false }; blend.SetResourceReference(Border.BackgroundProperty, "PeshGlowSecondary");
        canvas.Children.Add(glow); canvas.Children.Add(blend); canvas.Children.Add(page); Content = canvas;
        home = Scroll(General()); ShowHome(); ApplyTheme(); SourceInitialized += (_, _) => ApplyTheme();
        processingTime.Text = ProcessingTimes.Read(store.DirectoryPath);
        var timingRefresh = new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(1), System.Windows.Threading.DispatcherPriority.Background, (_, _) => { if (IsVisible && !busy()) processingTime.Text = ProcessingTimes.Read(store.DirectoryPath); }, Dispatcher);
        Closed += (_, _) => { download?.Cancel(); timingRefresh.Stop(); };
    }
    static StackPanel Panel() => new() { Margin = new Thickness(20) };
    static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 5, 0, 5), LineHeight = 19 };
    static Button Button(string label, Action click) { var b = new Button { Content = label, Margin = new Thickness(0, 4, 0, 4), HorizontalAlignment = HorizontalAlignment.Left }; b.Click += (_, _) => click(); return b; }
    static ScrollViewer Scroll(UIElement content) => new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = content };
    internal void OpenHistoryPage() => ShowPage("View history", History, true);
    void ShowHome() => page.Content = home;
    void ShowPage(string title, Func<UIElement> create, bool cache)
    {
        if (cache && navigationPages.TryGetValue(title, out var saved)) { page.Content = saved; return; }
        var container = new DockPanel();
        var bar = new Grid { Margin = new Thickness(20, 12, 20, 0) };
        var heading = Text(title); heading.FontWeight = FontWeights.SemiBold; heading.HorizontalAlignment = HorizontalAlignment.Center; heading.VerticalAlignment = VerticalAlignment.Center;
        var back = Button("Back", ShowHome); back.Padding = new Thickness(12, 8, 12, 8); back.HorizontalAlignment = HorizontalAlignment.Left;
        bar.Children.Add(heading); bar.Children.Add(back); DockPanel.SetDock(bar, Dock.Top); container.Children.Add(bar); container.Children.Add(Scroll(create()));
        if (cache) navigationPages[title] = container;
        page.Content = container;
    }
    static StackPanel Section(StackPanel root, string title)
    {
        var label = Text(title.ToUpperInvariant()); label.FontFamily = new FontFamily("Consolas"); label.FontSize = 10; label.Margin = new Thickness(0, 5, 0, 7); label.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted"); root.Children.Add(label);
        var body = new StackPanel { Margin = new Thickness(16) };
        var card = new Border { Child = body, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(.75), Margin = new Thickness(0, 0, 0, 16) };
        card.SetResourceReference(Border.BackgroundProperty, "PeshCard"); card.SetResourceReference(Border.BorderBrushProperty, "PeshBorder"); root.Children.Add(card); return body;
    }
    void Navigate(StackPanel root, string title, string detail, Func<UIElement> create, bool cache = true)
    {
        var copy = new StackPanel(); var label = Text(title); label.FontWeight = FontWeights.SemiBold; label.Margin = new Thickness(0, 0, 0, 3); copy.Children.Add(label);
        var hint = Text(detail); hint.FontSize = 12; hint.Margin = new Thickness(0); hint.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted"); copy.Children.Add(hint);
        var row = new DockPanel(); var glyph = new NavigationGlyph(title) { Width = 20, Height = 24, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center }; DockPanel.SetDock(glyph, Dock.Left); row.Children.Add(glyph); var arrow = Text("›"); arrow.FontSize = 22; arrow.Margin = new Thickness(14, 0, 0, 0); arrow.VerticalAlignment = VerticalAlignment.Center; arrow.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted"); DockPanel.SetDock(arrow, Dock.Right); row.Children.Add(arrow); row.Children.Add(copy);
        var button = Button(title, () => ShowPage(title, create, cache)); button.Content = row; button.Padding = new Thickness(16); button.Margin = new Thickness(0, 0, 0, 10); button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        System.Windows.Automation.AutomationProperties.SetName(button, title); root.Children.Add(button);
    }
    static UIElement Header()
    {
        var header = new StackPanel { Margin = new Thickness(0, 4, 0, 24) }; var row = new DockPanel();
        var mark = new WaveformPreview("lines") { Width = 24, Height = 24, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center }; DockPanel.SetDock(mark, Dock.Right); row.Children.Add(mark);
        var pig = new Image { Width = 62, Height = 62, Margin = new Thickness(0, 0, 12, 0), Source = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/pFlow;component/Assets/PeshMark.png")) }; DockPanel.SetDock(pig, Dock.Left); row.Children.Add(pig);
        var identity = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; identity.Children.Add(new TextBlock { Text = "pFlow", FontSize = 32, FontWeight = FontWeights.Bold });
        var by = new TextBlock { Text = "B Y  P E S H", FontSize = 10, FontFamily = new FontFamily("Consolas"), Margin = new Thickness(2, 1, 0, 0) }; by.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted"); identity.Children.Add(by); row.Children.Add(identity); header.Children.Add(row);
        var line = new Border { Height = 2, CornerRadius = new CornerRadius(1), Margin = new Thickness(0, 18, 0, 0) }; line.SetResourceReference(Border.BackgroundProperty, "PeshGradient"); header.Children.Add(line); return header;
    }
    void Save() { try { store.SavePreferences(); appearance(); ApplyTheme(); } catch (Exception error) { MessageBox.Show(error.Message, "Settings were not saved"); } }
    void ApplyTheme() => PeshTheme.Apply(this, store.Preferences);
    void Check(StackPanel panel, string label, bool value, Action<bool> change)
    {
        var check = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 1, 0, 1) };
        System.Windows.Automation.AutomationProperties.SetName(check, label);
        void Changed(object sender, RoutedEventArgs e) { change(check.IsChecked == true); Save(); }
        check.Checked += Changed; check.Unchecked += Changed; panel.Children.Add(check);
    }
    UIElement General()
    {
        var root = Panel(); root.Children.Add(Header());
        AppearanceCard(root);
        StackPanel p;
        Navigate(root, "Templates", "Choose a report format or use plain dictation.", Templates);
        Navigate(root, "Usage statistics", "Daily words, speaking pace, and activity by app.", Statistics, false);
        Navigate(root, "View history", "Browse and copy past transcripts.", History);
        Navigate(root, "Dictionary", "Teach pFlow names and words it often gets wrong.", Dictionary);
        p = Section(root, "Shortcut"); p.Children.Add(Text("Activation key"));
        var activation = new ComboBox { ItemsSource = KeyLabels.Options(store.Preferences.ActivationKey), DisplayMemberPath = "Name", SelectedValuePath = "Id", SelectedValue = store.Preferences.ActivationKey, Margin = new Thickness(0, 0, 0, 8) };
        var optionStyle = new Style(typeof(ComboBoxItem), (Style)FindResource(typeof(ComboBoxItem)));
        optionStyle.Setters.Add(new Setter(System.Windows.Automation.AutomationProperties.NameProperty, new System.Windows.Data.Binding("Name")));
        activation.ItemContainerStyle = optionStyle;
        System.Windows.Automation.AutomationProperties.SetName(activation, "Activation key"); p.Children.Add(activation);
        KeyCapture? learning = null; bool updatingPicker = false;
        var shortcutHelp = Text(ShortcutHelp()); p.Children.Add(shortcutHelp);
        var shortcutNotice = Text("Choose a common key above, or press a key to set your own. Used alone, your chosen key records instead of its usual action. Shortcuts still work."); p.Children.Add(shortcutNotice);
        Button learn = null!, cancelKey = null!;
        System.Windows.Threading.DispatcherTimer timeout = null!;
        learn = Button("Press a key", BeginSelection); cancelKey = Button("Cancel key selection", () => CancelSelection()); cancelKey.Visibility = Visibility.Collapsed;
        var keyButtons = new WrapPanel(); keyButtons.Children.Add(learn); keyButtons.Children.Add(cancelKey); p.Children.Add(keyButtons);
        p.Children.Add(Text("Fn works only if your keyboard sends it as a keyboard key to Windows. Menu / App and App buttons may have different names; press yours to detect it. Escape cancels key selection and dictation."));
        timeout = new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(15),System.Windows.Threading.DispatcherPriority.Background,(_,_) => CancelSelection("No usable key was detected. Try another key. Some Fn buttons send no keyboard key to Windows."),Dispatcher); timeout.Stop();
        string ShortcutHelp() => $"Hold {KeyLabels.Name(ActivationKeys.Resolve(store.Preferences.ActivationKey))} to dictate. Release to insert. Double-tap within 300 ms for continuous recording; tap again to finish. Escape cancels. You can also click the waveform to start and stop; drag it to move.";
        void RefreshPicker() {
            updatingPicker = true;
            try { activation.ItemsSource = KeyLabels.Options(store.Preferences.ActivationKey); activation.SelectedValue = store.Preferences.ActivationKey; }
            finally { updatingPicker = false; }
            shortcutHelp.Text = ShortcutHelp();
        }
        void SaveKey(ActivationKey key) {
            string previous = store.Preferences.ActivationKey;
            if (busy() || !keyboard.CanRebind) { RefreshPicker(); shortcutNotice.Text = "Finish or cancel dictation and release its key before changing the shortcut."; return; }
            try {
                keyboard.SelectActivationKey(key.Id); store.Preferences.ActivationKey = key.Id;
                try { store.SavePreferences(); }
                catch { store.Preferences.ActivationKey = previous; keyboard.SelectActivationKey(previous); throw; }
                RefreshPicker(); shortcutNotice.Text = $"Activation key saved: {KeyLabels.Name(key)}.";
            } catch (Exception error) { RefreshPicker(); shortcutNotice.Text = error.Message; }
        }
        void CancelSelection(string message = "Key selection canceled.") {
            if (learning == null) return;
            learning = null; timeout.Stop(); keyboard.CancelKeyCapture(); activation.IsEnabled = true; learn.IsEnabled = true; cancelKey.Visibility = Visibility.Collapsed;
            shortcutNotice.Text = message;
        }
        void BeginSelection() {
            if (busy() || !keyboard.CanRebind) { shortcutNotice.Text = "Finish or cancel dictation and release its key first."; return; }
            try {
                Activate(); learning = keyboard.BeginKeyCapture(); activation.IsEnabled = false; learn.IsEnabled = false; cancelKey.Visibility = Visibility.Visible;
                shortcutNotice.Text = "Press one key on its own, then release it. Escape cancels."; timeout.Start();
            } catch (Exception error) { shortcutNotice.Text = error.Message; }
        }
        void Captured(KeyCapture owner, ActivationKey? key, string? issue) {
            if (!ReferenceEquals(owner,learning)) return;
            CancelSelection(issue ?? "Key detected.");
            if (key != null) SaveKey(key);
        }
        activation.SelectionChanged += (_, _) => {
            if (!updatingPicker && activation.SelectedValue is string id && id != store.Preferences.ActivationKey) SaveKey(ActivationKeys.Resolve(id));
        };
        var mapping = Text("Press an activation key to check what this keyboard sends."); mapping.FontSize = 12; mapping.SetResourceReference(TextBlock.ForegroundProperty,"PeshMuted"); p.Children.Add(mapping);
        void Mapping(uint vk, uint scan) {
            var selected = ActivationKeys.Resolve(keyboard.ActivationKey);
            mapping.Text = $"Last detected: {KeyLabels.Name(selected.Matches(vk,scan) ? selected : ActivationKeys.FromEvent(vk,scan))}. Keep Mac dictation off when checking VM keys.";
        }
        keyboard.PhysicalKey += Mapping; keyboard.KeyCaptured += Captured;
        Deactivated += (_,_) => CancelSelection(); StateChanged += (_,_) => { if (WindowState == WindowState.Minimized) CancelSelection(); };
        Closed += (_,_) => { CancelSelection(); timeout.Stop(); keyboard.PhysicalKey -= Mapping; keyboard.KeyCaptured -= Captured; };
        p = Section(root, "Dictation");
        Check(p, "Copy dictation to clipboard after insertion", store.Preferences.CopyDictationToClipboard, x => store.Preferences.CopyDictationToClipboard = x);
        Check(p, "Quiet start and stop sounds", store.Preferences.Sounds, x => store.Preferences.Sounds = x);
        Check(p, "Group long narrations into paragraphs", store.Preferences.Paragraphs, x => store.Preferences.Paragraphs = x);
        Check(p, "Clean up dictation (English)", store.Preferences.Cleanup, x => store.Preferences.Cleanup = x);
        p = Section(root, "Local intelligence");
        if (LocalTextModel.IsSupported) {
        Check(p, "Use the local text model for reports and optional AI cleanup", store.Preferences.UseLocalAI, x => store.Preferences.UseLocalAI = x);
        Check(p, "AI cleanup (slower, English)", store.Preferences.UseAICleanup, x => store.Preferences.UseAICleanup = x);
        p.Children.Add(Text("English cleanup removes filler words immediately. Other languages keep their recognized words. AI cleanup is optional, English only, and can take up to eight seconds. Blocks with numbers, quotes, contractions, or symbols keep their original words. Reports use your sentences."));
        p.Children.Add(Text(textModel.FilesPresent ? "Local text model installed. Processing stays on this PC." : "Local AI is unavailable until its model is installed. Plain dictation still works."));
        p.Children.Add(Button("Download or repair text model (2.5 GB)", DownloadTextModel));
        } else p.Children.Add(Text(LocalTextModel.UnsupportedReason));
        p = Section(root, "Speech recognition");
        p.Children.Add(Text("Language"));
        var languages = new Dictionary<string, string> { ["en"] = "English", ["es"] = "Spanish", ["fr"] = "French", ["de"] = "German", ["it"] = "Italian", ["pt"] = "Portuguese", ["zh"] = "Chinese", ["ja"] = "Japanese", ["ko"] = "Korean", ["hi"] = "Hindi", ["ar"] = "Arabic" };
        if (!languages.ContainsKey(store.Preferences.Language)) languages[store.Preferences.Language] = store.Preferences.Language;
        var language = new ComboBox { ItemsSource = languages, DisplayMemberPath = "Value", SelectedValuePath = "Key", SelectedValue = store.Preferences.Language, Margin = new Thickness(0, 0, 0, 10) };
        System.Windows.Automation.AutomationProperties.SetName(language, "Speech language");
        language.SelectionChanged += (_, _) => { if (language.SelectedValue is string value) { store.Preferences.Language = value; store.SavePreferences(); } };
        p.Children.Add(language);
        p.Children.Add(processingTime);
        p.Children.Add(Text($"Microphone devices: {WaveRecorder.waveInGetNumDevs()}. Windows microphone access must allow desktop apps."));
        p.Children.Add(Button("Download or repair Whisper model (488 MB)", Download));
        p.Children.Add(Button("Cancel download", () => download?.Cancel())); p.Children.Add(notice);
        p = Section(root, "General");
        using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            Check(p, "Launch pFlow when I sign in", run?.GetValue("pFlow by Pesh") != null, SetStartup);
        p = Section(root, "Updates"); p.Children.Add(Text("pFlow " + UpdateWindow.CurrentVersion));
        p.Children.Add(Button("Check for updates", () => this.checkUpdates?.Invoke()));
        p.Children.Add(Text("Checks GitHub only when you ask. Settings and History are kept during updates."));
        p = Section(root, "Privacy"); p.Children.Add(Text("Recordings are deleted after processing. Settings and History stay in your Windows user folder. Model downloads need the internet; recording and transcription do not. No cloud model or account is used."));
        return root;
    }
    void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("pFlow by Pesh", "\"" + Environment.ProcessPath + "\""); else key.DeleteValue("pFlow by Pesh", false);
    }
    async void Download()
    {
        if (download != null || busy()) { notice.Text = "Finish or cancel dictation first."; return; }
        download = new CancellationTokenSource();
        try { await whisper.Download(new Progress<double>(v => notice.Text = $"Downloading model: {v:P0}"), download.Token); notice.Text = "Whisper model checksum verified. Ready for offline dictation."; }
        catch (OperationCanceledException) { notice.Text = "Download canceled."; }
        catch (Exception e) { notice.Text = e.Message; }
        finally { download.Dispose(); download = null; }
    }
    async void DownloadTextModel()
    {
        if (download != null || busy()) { notice.Text = "Finish or cancel dictation first."; return; }
        download = new CancellationTokenSource();
        try { await textModel.Download(new Progress<double>(v => notice.Text = $"Downloading text model: {v:P0}"), download.Token); notice.Text = "Text model checksum verified. Local AI is ready."; }
        catch (OperationCanceledException) { notice.Text = "Download canceled."; }
        catch (Exception e) { notice.Text = e.Message; }
        finally { download.Dispose(); download = null; }
    }
    UIElement Dictionary()
    {
        var p = Panel(); p.Children.Add(Text("Learned terms bias Whisper. Exact replacements change only whole words or phrases and never cascade."));
        var terms = new TextBox { Text = string.Join("\n", store.Preferences.DictionaryTerms), AcceptsReturn = true, Height = 100, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; p.Children.Add(terms);
        p.Children.Add(Button("Save learned terms", () => { store.Preferences.DictionaryTerms = terms.Text.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList(); Save(); }));
        var list = new ListBox { Height = 150 }; void Refresh() => list.ItemsSource = store.Preferences.DictionaryReplacements.Select(x => $"{x.Heard} → {x.Replacement}").ToList(); Refresh(); p.Children.Add(list);
        p.Children.Add(Text("Heard")); var heard = new TextBox(); p.Children.Add(heard); p.Children.Add(Text("Replace with")); var replacement = new TextBox(); p.Children.Add(replacement);
        p.Children.Add(Button("Save replacement", () => { if (string.IsNullOrWhiteSpace(heard.Text) || string.IsNullOrWhiteSpace(replacement.Text)) return; var entry = store.Preferences.DictionaryReplacements.FirstOrDefault(x => x.Heard.Equals(heard.Text.Trim(), StringComparison.OrdinalIgnoreCase)); if (entry == null) store.Preferences.DictionaryReplacements.Insert(0, new() { Heard = heard.Text.Trim(), Replacement = replacement.Text.Trim() }); else entry.Replacement = replacement.Text.Trim(); Save(); Refresh(); }));
        p.Children.Add(Button("Delete selected replacement", () => { if (list.SelectedIndex >= 0) { store.Preferences.DictionaryReplacements.RemoveAt(list.SelectedIndex); Save(); Refresh(); } }));
        return p;
    }
    UIElement Templates()
    {
        var p = Panel(); p.Children.Add(Text("Create your own templates, or use plain dictation without a format. Give a new template a name, then edit and save its sections below."));
        var picker = new ComboBox { DisplayMemberPath = "Name", ItemsSource = store.Preferences.Templates, SelectedItem = store.Preferences.Templates.FirstOrDefault(x => x.Id == store.Preferences.ActiveTemplateId) }; System.Windows.Automation.AutomationProperties.SetName(picker, "Your templates"); p.Children.Add(picker);
        var empty = Text("No templates yet. Create one below whenever you need it."); empty.Visibility = store.Preferences.Templates.Count == 0 ? Visibility.Visible : Visibility.Collapsed; p.Children.Add(empty);
        var editor = new TextBox { AcceptsReturn = true, AcceptsTab = true, FontFamily = new FontFamily("Consolas"), Height = 280, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        p.Children.Add(Text("Template name")); var name = new TextBox(); System.Windows.Automation.AutomationProperties.SetName(name, "Template name"); p.Children.Add(name);
        var create = Button("New template", () => { var t = new DictationTemplate { Name = name.Text.Trim(), Sections = [new() { Title = "Narrative", IncludeFullDictation = true }] }; editor.Text = JsonSerializer.Serialize(t, StateStore.Json); });
        create.IsEnabled = false; name.TextChanged += (_, _) => create.IsEnabled = !string.IsNullOrWhiteSpace(name.Text); p.Children.Add(create);
        picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is DictationTemplate t) { store.Preferences.ActiveTemplateId = t.Id; editor.Text = JsonSerializer.Serialize(t, StateStore.Json); Save(); } };
        if (picker.SelectedItem is DictationTemplate selected) editor.Text = JsonSerializer.Serialize(selected, StateStore.Json);
        p.Children.Add(Button("Use plain dictation", () => { picker.SelectedItem = null; store.Preferences.ActiveTemplateId = null; Save(); })); p.Children.Add(editor);
        p.Children.Add(Button("Save template JSON", () => {
            try {
                var t = JsonSerializer.Deserialize<DictationTemplate>(editor.Text, StateStore.Json) ?? throw new InvalidDataException("Enter a template first.");
                if (string.IsNullOrWhiteSpace(t.Name) || t.Sections == null || t.Sections.Count == 0 || t.Sections.Any(x => x == null || x.Title == null)) throw new InvalidDataException("A template needs a name and sections.");
                int index = store.Preferences.Templates.FindIndex(x => x.Id == t.Id); if (index < 0) store.Preferences.Templates.Add(t); else store.Preferences.Templates[index] = t;
                store.Preferences.ActiveTemplateId = t.Id; empty.Visibility = Visibility.Collapsed; picker.ItemsSource = null; picker.ItemsSource = store.Preferences.Templates; picker.SelectedItem = t; Save();
            } catch (Exception e) { MessageBox.Show(e.Message, "Template was not saved"); }
        }));

        return p;
    }
    UIElement History()
    {
        var p = Panel(); var list = new ListBox { Height = 180, DisplayMemberPath = "CreatedAt", ItemsSource = store.History.ToList() }; p.Children.Add(list);
        var text = new TextBox { AcceptsReturn = true, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 230, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; p.Children.Add(text);
        var result = Text(""); p.Children.Add(result);
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is Transcript t) { text.Text = t.Text; result.Text = t.InsertionStatus; } };
        p.Children.Add(Button("Copy selected dictation", () => { if (list.SelectedItem is Transcript t) Clipboard.SetText(t.Text); }));
        p.Children.Add(Button("Delete selected dictation", () => { if (list.SelectedItem is Transcript t) { store.Delete(t.Id); list.ItemsSource = store.History.ToList(); text.Clear(); } }));
        p.Children.Add(Button("Refresh History", () => list.ItemsSource = store.History.ToList())); return p;
    }
}
