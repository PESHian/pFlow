using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;

namespace PFlow.Windows;

/// The words heard so far, in a calm floating card near the recording control
/// while a take with Live text runs. Same shape as the Mac card: a header with
/// the Pesh mark, a recording dot and a short caption; a hairline; then the
/// transcript filling a fixed box of whole lines from the bottom, its top line
/// fading out. The box never changes size while the
/// words grow. The recording control under the card already shows the
/// waveform, so the card carries none.
/// It never takes focus or the text cursor: shown without activation, refuses
/// activation by click (WS_EX_NOACTIVATE, MA_NOACTIVATE), lets clicks pass
/// through, has no taskbar entry, and never uses the clipboard.
internal sealed class LivePreview : Window
{
    const int ExStyle = -20, NoActivate = 0x08000000, ToolWindow = 0x80, Transparent = 0x20, MouseActivate = 0x21, PointerActivate = 0x24B, NoActivateReply = 3;
    const double BaseWidth = 380, Gap = 4, ShadowMargin = 12, BoxLines = 4;
    readonly StateStore store;
    readonly Border card, dot, rule;
    readonly TextBlock caption, words;
    readonly Grid lines;
    readonly Image mark;
    readonly DropShadowEffect shadow;
    string? note;
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    internal string Shown => words.Text;
    internal string Caption => caption.Text;
    internal string? Note => note;
    internal double LinesHeight => lines.Height;
    internal double WordsLineHeight => words.LineHeight;
    internal FrameworkElement Card => card;
    internal Brush CaptionBrush => caption.Foreground;
    internal Brush WordsBrush => words.Foreground;
    internal int Updates { get; private set; }

    internal LivePreview(StateStore store)
    {
        this.store = store;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false; IsHitTestVisible = false;
        SizeToContent = SizeToContent.Height;

        mark = new Image { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        try { mark.Source = new BitmapImage(new Uri("pack://application:,,,/pFlow;component/Assets/PeshMark.png")); } catch { mark.Visibility = Visibility.Collapsed; }
        dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        dot.SetResourceReference(Border.BackgroundProperty, "PeshRecording");
        caption = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted");
        var header = new Grid { Height = 20 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(dot, 1); Grid.SetColumn(caption, 2);
        header.Children.Add(mark); header.Children.Add(dot); header.Children.Add(caption);

        rule = new Border { Height = 1, Margin = new Thickness(0, 8, 0, 8) };
        rule.SetResourceReference(Border.BackgroundProperty, "PeshBorder");

        words = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Bottom, LineStackingStrategy = LineStackingStrategy.BlockLineHeight };
        words.SetResourceReference(TextBlock.ForegroundProperty, "PeshText");
        // A box of whole lines (every line is exactly LineHeight tall), so its top falls between
        // two lines and no glyph is cut; the top line fades out.
        lines = new Grid { ClipToBounds = true };
        lines.OpacityMask = new LinearGradientBrush(new GradientStopCollection {
            new(Colors.Transparent, 0), new(Colors.Black, 1 / BoxLines) }, new Point(0, 0), new Point(0, 1));
        lines.Children.Add(words);

        var stack = new StackPanel(); stack.Children.Add(header); stack.Children.Add(rule); stack.Children.Add(lines);
        shadow = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 2, Direction = 270, Color = Colors.Black };
        card = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = new Thickness(16, 12, 16, 14), Margin = new Thickness(ShadowMargin), Child = stack, Effect = shadow };
        card.SetResourceReference(Border.BackgroundProperty, "PeshFloating");
        card.SetResourceReference(Border.BorderBrushProperty, "PeshBorder");
        Content = card;
        System.Windows.Automation.AutomationProperties.SetName(this, "pFlow live preview");
        SourceInitialized += (_, _) => {
            Native.SetWindowLongPtr(Handle, ExStyle, (IntPtr)(Native.GetWindowLongPtr(Handle, ExStyle).ToInt64() | NoActivate | ToolWindow | Transparent));
            HwndSource.FromHwnd(Handle)?.AddHook((IntPtr hwnd, int msg, IntPtr wp, IntPtr lp, ref bool handled) => {
                if (msg is MouseActivate or PointerActivate) { handled = true; return (IntPtr)NoActivateReply; }
                return IntPtr.Zero;
            });
        };
        ApplyTheme(); ApplyTextSize();
    }

    /// Windows "Text size" (Accessibility) applies to the preview, up to 225%.
    internal static double TextScale()
    {
        object? value = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Accessibility", "TextScaleFactor", 100);
        return value is int percent ? Math.Clamp(percent / 100.0, 1, 2.25) : 1;
    }

    internal void ApplyTextSize(double? scale = null)
    {
        double factor = scale ?? TextScale();
        caption.FontSize = 12 * factor; words.FontSize = 14 * factor; words.LineHeight = 20 * factor;
        lines.Height = words.LineHeight * BoxLines;
        Width = BaseWidth * (1 + (factor - 1) / 2) + 2 * ShadowMargin;
    }

    internal void ApplyTheme()
    {
        PeshTheme.Apply(this, store.Preferences);
        Background = Brushes.Transparent;
        shadow.Opacity = PeshTheme.Light(store.Preferences) ? .18 : .5;
    }

    /// A new take: clear everything from the previous one.
    internal void Begin() { note = null; Updates = 0; words.Text = ""; caption.Text = "Listening"; Pulse(true); }

    internal void ShowText(string text) { Updates++; words.Text = LivePreviewText.Tail(text); }

    internal void SetNote(string value) { note = value; caption.Text = value; }

    internal void Finishing() { caption.Text = "Finishing…"; Pulse(false); }

    internal void Reveal(IntPtr control)
    {
        if (!IsVisible) Show();
        Place(control);
    }

    internal void Clear() { Hide(); Pulse(false); Begin(); }

    /// The recording dot breathes while pFlow listens; still when Windows
    /// animations are off.
    void Pulse(bool on)
    {
        if (on && SystemParameters.ClientAreaAnimation) {
            dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, .35, TimeSpan.FromSeconds(.9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        } else { dot.BeginAnimation(OpacityProperty, null); dot.Opacity = 1; }
    }

    void Place(IntPtr control)
    {
        if (Handle == IntPtr.Zero || control == IntPtr.Zero || !Native.GetWindowRect(control, out var anchor)) return;
        var screens = System.Windows.Forms.Screen.AllScreens;
        var display = System.Windows.Forms.Screen.FromHandle(control).WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(this);
        // Small displays: never wider than the work area, with a margin.
        double room = display.Width / dpi.DpiScaleX - 2 * Gap;
        if (Width > room) Width = Math.Max(160 + 2 * ShadowMargin, room);
        UpdateLayout();
        if (!Native.GetWindowRect(Handle, out var bounds)) return;
        var point = LivePreviewPlacement.Place(screens.Select(screen => new WorkArea(screen.WorkingArea.X, screen.WorkingArea.Y, screen.WorkingArea.Width, screen.WorkingArea.Height)).ToArray(),
            new WorkArea(anchor.Left, anchor.Top, anchor.Right - anchor.Left, anchor.Bottom - anchor.Top), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, Gap * dpi.DpiScaleY);
        // Move in physical pixels without activating, resizing or changing z-order.
        Native.SetWindowPos(Handle, IntPtr.Zero, (int)Math.Round(point.X), (int)Math.Round(point.Y), 0, 0, 0x15);
    }
}
