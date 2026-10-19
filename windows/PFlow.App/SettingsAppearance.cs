namespace PFlow.Windows;

internal sealed partial class SettingsWindow
{
    void AppearanceCard(StackPanel root)
    {
        var body = Section(root, "Make it yours");
        var heading = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        heading.ColumnDefinitions.Add(new ColumnDefinition());
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text("Appearance"); title.FontWeight = FontWeights.SemiBold; title.VerticalAlignment = VerticalAlignment.Center;
        heading.Children.Add(title);
        var modes = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3 };
        var segment = new Border { Child = modes, Width = 205, Padding = new Thickness(2), CornerRadius = new CornerRadius(7) };
        segment.SetResourceReference(Border.BackgroundProperty, "PeshSegment"); Grid.SetColumn(segment, 1); heading.Children.Add(segment);
        foreach (string mode in new[] { "dark", "light", "system" })
            modes.Children.Add(Option(mode, mode[0].ToString().ToUpperInvariant() + mode[1..], "Appearance", store.Preferences.Theme == mode,
                "AppearanceSegment", () => { store.Preferences.Theme = mode; Save(); }));
        body.Children.Add(heading);

        var palettes = new System.Windows.Controls.Primitives.UniformGrid { Columns = 4, Margin = new Thickness(-5, 0, -5, 16) };
        var custom = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(-5, 0, -5, 16) };
        var customPreview = new Border { Height = 7, CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 0, 0, 7) };
        void UpdateCustom()
        {
            custom.Visibility = store.Preferences.Palette == "custom" ? Visibility.Visible : Visibility.Collapsed;
            customPreview.Background = PeshTheme.Gradient(new Preferences { Palette = "custom", CustomAccent = store.Preferences.CustomAccent, Accent = store.Preferences.Accent, WaveBlend = store.Preferences.WaveBlend });
        }
        foreach (string palette in new[] { "pesh", "aurora", "solar", "custom" }) {
            string caption = palette[0].ToString().ToUpperInvariant() + palette[1..];
            var content = new StackPanel();
            var swatch = palette == "custom" ? customPreview : new Border { Height = 7, CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 0, 0, 7), Background = PeshTheme.Gradient(new Preferences { Palette = palette }) };
            content.Children.Add(swatch); content.Children.Add(new TextBlock { Text = caption, FontSize = 11, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
            var choice = Option(palette, caption + " colors", "Colors", store.Preferences.Palette == palette, "AppearanceChoice", () => {
                store.Preferences.Palette = palette;
                store.Preferences.Accent = palette switch { "aurora" => "4EE5B3", "solar" => "FFBB66", "custom" => store.Preferences.CustomAccent ?? "FF9DC4", _ => "FF9DC4" };
                Save(); UpdateCustom();
            });
            choice.Content = content; choice.Margin = new Thickness(5, 0, 5, 0); palettes.Children.Add(choice);
        }
        body.Children.Add(palettes);
        custom.Children.Add(ColorChoice("Accent", () => store.Preferences.CustomAccent ?? "FF9DC4", value => { store.Preferences.CustomAccent = value; store.Preferences.Accent = value; }, UpdateCustom));
        custom.Children.Add(ColorChoice("Wave blend", () => store.Preferences.WaveBlend, value => store.Preferences.WaveBlend = value, UpdateCustom));
        body.Children.Add(custom); UpdateCustom();
        var help = Text("Colors follow you from the app to the recording waveform."); help.FontSize = 11; help.LineHeight = 16; help.Margin = new Thickness(0, 0, 0, 16); help.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted"); body.Children.Add(help);
        var waveTitle = Text("Waveform"); waveTitle.FontWeight = FontWeights.SemiBold; waveTitle.Margin = new Thickness(0, 0, 0, 16); body.Children.Add(waveTitle);
        var waves = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(-5, 0, -5, 0) };
        foreach (string wave in new[] { "wave", "lines" }) {
            string caption = wave == "wave" ? "Wave" : "Lines";
            var content = new StackPanel(); content.Children.Add(new WaveformPreview(wave) { Width = 100, Height = 20, Margin = new Thickness(0, 0, 0, 9), HorizontalAlignment = HorizontalAlignment.Center });
            content.Children.Add(new TextBlock { Text = caption, FontSize = 11, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
            var choice = Option(wave, caption + " waveform", "Waveform", store.Preferences.Waveform == wave, "AppearanceChoice", () => { store.Preferences.Waveform = wave; Save(); });
            choice.Content = content; choice.Padding = new Thickness(12); choice.Margin = new Thickness(5, 0, 5, 0); waves.Children.Add(choice);
        }
        body.Children.Add(waves);
    }

    RadioButton Option(string value, string label, string group, bool selected, string style, Action change)
    {
        var option = new RadioButton { Content = label, Tag = value, GroupName = group, IsChecked = selected, Style = (Style)Resources[style] };
        System.Windows.Automation.AutomationProperties.SetName(option, label);
        option.Checked += (_, _) => change(); return option;
    }

    Button ColorChoice(string label, Func<string> value, Action<string> change, Action updated)
    {
        var row = new DockPanel();
        var swatch = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Margin = new Thickness(0, 0, 8, 0), Background = (Brush)new BrushConverter().ConvertFromString("#" + value())! };
        DockPanel.SetDock(swatch, Dock.Right); row.Children.Add(swatch);
        var text = Text(label); text.FontSize = 12; text.Margin = new Thickness(0); row.Children.Add(text);
        var button = Button(label, () => {
            using var picker = new System.Windows.Forms.ColorDialog { FullOpen = true, Color = System.Drawing.ColorTranslator.FromHtml("#" + value()) };
            if (picker.ShowDialog(new ColorDialogOwner(new System.Windows.Interop.WindowInteropHelper(this).Handle)) != System.Windows.Forms.DialogResult.OK) return;
            string hex = $"{picker.Color.R:X2}{picker.Color.G:X2}{picker.Color.B:X2}";
            change(hex); Save(); updated(); swatch.Background = (Brush)new BrushConverter().ConvertFromString("#" + hex)!;
        });
        button.Content = row; button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Padding = new Thickness(8); button.Margin = new Thickness(5, 0, 5, 0);
        System.Windows.Automation.AutomationProperties.SetName(button, label + " color"); return button;
    }

    sealed class ColorDialogOwner(IntPtr handle) : System.Windows.Forms.IWin32Window { public IntPtr Handle => handle; }
}
