using System.Windows.Interop;

namespace PFlow.Windows;

/// The words heard so far, shown near the recording control while a take with
/// Live text runs. It never takes focus or the text cursor: it is shown without
/// activation, refuses activation by click (WS_EX_NOACTIVATE, MA_NOACTIVATE),
/// lets clicks pass through, has no taskbar entry, and never uses the clipboard.
internal sealed class LivePreview : Window
{
    const int ExStyle = -20, NoActivate = 0x08000000, ToolWindow = 0x80, Transparent = 0x20, MouseActivate = 0x21, NoActivateReply = 3;
    const double BaseWidth = 380, Gap = 8;
    readonly StateStore store;
    readonly Border card;
    readonly TextBlock header, words;
    readonly Grid lines;
    string? note;
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    internal string Shown => words.Text;
    internal string Header => header.Text;
    internal int Updates { get; private set; }

    internal LivePreview(StateStore store)
    {
        this.store = store;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false; IsHitTestVisible = false;
        SizeToContent = SizeToContent.Height;
        header = new TextBlock { Margin = new Thickness(0, 0, 0, 4), TextTrimming = TextTrimming.CharacterEllipsis };
        header.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted");
        words = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Bottom, LineStackingStrategy = LineStackingStrategy.BlockLineHeight };
        words.SetResourceReference(TextBlock.ForegroundProperty, "PeshText");
        // The newest three lines: older lines scroll up out of the clipped area.
        lines = new Grid { ClipToBounds = true }; lines.Children.Add(words);
        var stack = new StackPanel(); stack.Children.Add(header); stack.Children.Add(lines);
        card = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(14, 10, 14, 12), Child = stack };
        card.SetResourceReference(Border.BackgroundProperty, "PeshBackground");
        Content = card;
        System.Windows.Automation.AutomationProperties.SetName(this, "pFlow live preview");
        SourceInitialized += (_, _) => {
            Native.SetWindowLongPtr(Handle, ExStyle, (IntPtr)(Native.GetWindowLongPtr(Handle, ExStyle).ToInt64() | NoActivate | ToolWindow | Transparent));
            HwndSource.FromHwnd(Handle)?.AddHook((IntPtr hwnd, int msg, IntPtr wp, IntPtr lp, ref bool handled) => {
                if (msg == MouseActivate) { handled = true; return (IntPtr)NoActivateReply; }
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
        header.FontSize = 11.5 * factor; words.FontSize = 15 * factor; words.LineHeight = 21 * factor;
        lines.Height = words.LineHeight * 3;
        Width = BaseWidth * (1 + (factor - 1) / 2);
    }

    internal void ApplyTheme()
    {
        PeshTheme.Apply(this, store.Preferences);
        Background = Brushes.Transparent;
        card.BorderBrush = (Brush)Resources["PeshAccent"];
    }

    /// A new take: clear everything from the previous one.
    internal void Begin() { note = null; Updates = 0; words.Text = ""; header.Text = "Listening…"; }

    internal void ShowText(string text)
    {
        Updates++;
        words.Text = LivePreviewText.Tail(text);
        if (note == null) header.Text = "Live preview";
    }

    internal void SetNote(string value) { note = value; header.Text = value; }

    internal void Finishing() { if (note == null) header.Text = "Finishing…"; }

    internal void Reveal(IntPtr control)
    {
        if (!IsVisible) Show();
        Place(control);
    }

    internal void Clear() { Hide(); Begin(); }

    void Place(IntPtr control)
    {
        if (Handle == IntPtr.Zero || control == IntPtr.Zero || !Native.GetWindowRect(control, out var anchor)) return;
        var screens = System.Windows.Forms.Screen.AllScreens;
        var display = System.Windows.Forms.Screen.FromHandle(control).WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(this);
        // Small displays: never wider than the work area, with a margin.
        double room = display.Width / dpi.DpiScaleX - 2 * Gap;
        if (Width > room) Width = Math.Max(160, room);
        UpdateLayout();
        if (!Native.GetWindowRect(Handle, out var bounds)) return;
        var point = LivePreviewPlacement.Place(screens.Select(screen => new WorkArea(screen.WorkingArea.X, screen.WorkingArea.Y, screen.WorkingArea.Width, screen.WorkingArea.Height)).ToArray(),
            new WorkArea(anchor.Left, anchor.Top, anchor.Right - anchor.Left, anchor.Bottom - anchor.Top), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, Gap * dpi.DpiScaleY);
        // Move in physical pixels without activating, resizing or changing z-order.
        Native.SetWindowPos(Handle, IntPtr.Zero, (int)Math.Round(point.X), (int)Math.Round(point.Y), 0, 0, 0x15);
    }
}
