using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;

namespace PFlow.Windows;

/// A small card in the look of the live text card, for two moments: the
/// finished words when they could not go into the app (selectable, with a
/// Copy button), and the one notice at a fresh start. Shown without taking
/// focus; it takes focus only when the person clicks or taps it, so a
/// selection and Ctrl+C work there. Never touches the clipboard unless Copy is
/// pressed. No taskbar entry. Stays until closed, the next take, or (for the
/// notice) its own timer.
internal sealed class PromptCard : Window
{
    const int ExStyle = -20, ToolWindow = 0x80;
    const double BaseWidth = 380, Gap = 4, ShadowMargin = 12, TouchButton = 44;
    readonly StateStore store;
    readonly Border card, rule;
    readonly TextBlock title, reason, hint;
    readonly TextBox words;
    readonly Button copy, close, secondary;
    readonly DropShadowEffect shadow;
    readonly System.Windows.Threading.DispatcherTimer copied, expiry, watch;
    /// How long the words card stays before it hides on its own.
    internal static readonly TimeSpan WordsLifetime = TimeSpan.FromMinutes(3);
    readonly Image mark;
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    internal string Title_ => title.Text;
    internal string Reason => reason.Text;
    internal string Words => words.Text;
    internal string CopyLabel => (string)copy.Content;
    internal bool CopyShown => copy.Visibility == Visibility.Visible;
    internal bool WordsShown => words.Visibility == Visibility.Visible;
    internal FrameworkElement Card => card;
    internal Brush TitleBrush => title.Foreground;
    internal Brush ReasonBrush => reason.Foreground;
    internal Brush WordsBrush => words.Foreground;
    internal Brush WordsBackground => words.Background;
    internal Brush CopyBrush => copy.Foreground;
    internal Brush CopyBackground => copy.Background;
    internal double CopyHeight => copy.ActualHeight;
    /// Copies made by the Copy button (a test counts them).
    internal int Copies { get; private set; }
    internal event Action? SecondaryPressed;

    internal PromptCard(StateStore store)
    {
        this.store = store;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; SizeToContent = SizeToContent.Height;
        Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(new Uri("/pFlow;component/SettingsStyles.xaml", UriKind.Relative)));

        mark = new Image { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        try { mark.Source = new BitmapImage(new Uri("pack://application:,,,/pFlow;component/Assets/PeshMark.png")); } catch { mark.Visibility = Visibility.Collapsed; }
        title = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        title.SetResourceReference(TextBlock.ForegroundProperty, "PeshText");
        close = new Button { Content = "×", Width = 36, Height = 36, Padding = new Thickness(0), FontSize = 18, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Close" };
        System.Windows.Automation.AutomationProperties.SetName(close, "Close");
        close.Click += (_, _) => Dismiss();
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(title, 1); Grid.SetColumn(close, 2);
        header.Children.Add(mark); header.Children.Add(title); header.Children.Add(close);

        rule = new Border { Height = 1, Margin = new Thickness(0, 6, 0, 10) };
        rule.SetResourceReference(Border.BackgroundProperty, "PeshBorder");
        reason = new TextBlock { TextWrapping = TextWrapping.Wrap };
        reason.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted");

        words = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Margin = new Thickness(0, 10, 0, 0), Padding = new Thickness(10, 8, 10, 8), BorderThickness = new Thickness(1) };
        words.SetResourceReference(TextBox.ForegroundProperty, "PeshText"); words.SetResourceReference(TextBox.BackgroundProperty, "PeshInput");
        words.SetResourceReference(TextBox.BorderBrushProperty, "PeshBorder"); words.SetResourceReference(TextBox.SelectionBrushProperty, "PeshAccent");
        System.Windows.Automation.AutomationProperties.SetName(words, "Dictated words");
        hint = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
        hint.SetResourceReference(TextBlock.ForegroundProperty, "PeshMuted");

        copy = new Button { Content = InsertionPrompt.Copy, MinHeight = TouchButton, MinWidth = 120, FontWeight = FontWeights.SemiBold, BorderThickness = new Thickness(0), Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        copy.SetResourceReference(Button.BackgroundProperty, "PeshAccent"); copy.SetResourceReference(Button.ForegroundProperty, "PeshAccentInk");
        System.Windows.Automation.AutomationProperties.SetName(copy, "Copy dictated words");
        copy.Click += (_, _) => CopyWords();
        secondary = new Button { MinHeight = TouchButton, MinWidth = 120, Margin = new Thickness(10, 12, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        secondary.SetResourceReference(Button.BackgroundProperty, "PeshTile");
        secondary.Click += (_, _) => { SecondaryPressed?.Invoke(); Dismiss(); };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal }; buttons.Children.Add(copy); buttons.Children.Add(secondary);

        var stack = new StackPanel(); stack.Children.Add(header); stack.Children.Add(rule); stack.Children.Add(reason); stack.Children.Add(words); stack.Children.Add(hint); stack.Children.Add(buttons);
        shadow = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 2, Direction = 270, Color = Colors.Black };
        card = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = new Thickness(16, 12, 16, 16), Margin = new Thickness(ShadowMargin), Child = stack, Effect = shadow };
        card.SetResourceReference(Border.BackgroundProperty, "PeshFloating"); card.SetResourceReference(Border.BorderBrushProperty, "PeshBorder");
        Content = card;
        System.Windows.Automation.AutomationProperties.SetName(this, "pFlow prompt");
        SourceInitialized += (_, _) => Native.SetWindowLongPtr(Handle, ExStyle, (IntPtr)(Native.GetWindowLongPtr(Handle, ExStyle).ToInt64() | ToolWindow));
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { Dismiss(); e.Handled = true; } };
        copied = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        copied.Tick += (_, _) => { copied.Stop(); copy.Content = InsertionPrompt.Copy; };
        expiry = new System.Windows.Threading.DispatcherTimer();
        expiry.Tick += (_, _) => Dismiss();
        // A card left open goes away on its own (the words stay in History), and at once when a
        // full-screen app (a game, a video) is in front, so it never sits over one.
        watch = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        watch.Tick += (_, _) => { if (IsVisible && FullScreenInFront()) Dismiss(); };
        ApplyTheme(); ApplyTextSize();
    }

    internal void ApplyTextSize(double? scale = null)
    {
        double factor = scale ?? LivePreview.TextScale();
        title.FontSize = 14 * factor; reason.FontSize = 13 * factor; hint.FontSize = 12 * factor; words.FontSize = 15 * factor; copy.FontSize = secondary.FontSize = 14 * factor;
        words.MaxHeight = 22 * factor * 7 + 16;
        Width = BaseWidth * (1 + (factor - 1) / 2) + 2 * ShadowMargin;
    }

    internal void ApplyTheme()
    {
        PeshTheme.Apply(this, store.Preferences);
        Background = Brushes.Transparent;
        shadow.Opacity = PeshTheme.Light(store.Preferences) ? .18 : .5;
    }

    /// The finished words that could not go in, with the plain reason. Shown near `anchor` (the recording control).
    internal void ShowWords(string text, string status, IntPtr anchor)
    {
        expiry.Stop(); copied.Stop();
        title.Text = InsertionPrompt.Title; reason.Text = InsertionPrompt.Reason(status); words.Text = text; hint.Text = InsertionPrompt.Hint;
        words.Visibility = hint.Visibility = copy.Visibility = Visibility.Visible; secondary.Visibility = Visibility.Collapsed; copy.Content = InsertionPrompt.Copy;
        secondary.Margin = new Thickness(10, 12, 0, 0);
        Reveal(anchor);
        expiry.Interval = WordsLifetime; expiry.Start();
    }

    /// The start notice: where pFlow is and how to dictate; goes away on its own after `lifetime`.
    internal void ShowNotice(string body, string secondaryLabel, TimeSpan lifetime)
    {
        expiry.Stop(); copied.Stop();
        title.Text = StartNotice.Title; reason.Text = body; words.Text = ""; hint.Text = "";
        words.Visibility = hint.Visibility = copy.Visibility = Visibility.Collapsed; secondary.Visibility = Visibility.Visible; secondary.Content = secondaryLabel;
        secondary.Margin = new Thickness(0, 12, 0, 0);
        Reveal(IntPtr.Zero);
        if (lifetime > TimeSpan.Zero) { expiry.Interval = lifetime; expiry.Start(); }
    }

    /// Hides the card and lets the words go; they stay in History.
    internal void Dismiss() { expiry.Stop(); copied.Stop(); watch.Stop(); if (IsVisible) Hide(); words.Text = ""; reason.Text = ""; }

    /// True when the window in front fills its whole display (not the desktop or the taskbar).
    static bool FullScreenInFront()
    {
        IntPtr front = Native.GetForegroundWindow();
        if (front == IntPtr.Zero || !Native.GetWindowRect(front, out var at)) return false;
        var screen = System.Windows.Forms.Screen.FromHandle(front).Bounds;
        if (at.Left > screen.Left || at.Top > screen.Top || at.Right < screen.Right || at.Bottom < screen.Bottom) return false;
        var name = new System.Text.StringBuilder(64); Native.GetClassName(front, name, name.Capacity);
        return name.ToString() is not ("Progman" or "WorkerW" or "Shell_TrayWnd");
    }

    void CopyWords()
    {
        try { ClipboardLease.KeepCopy(Handle, words.Text); Copies++; copy.Content = InsertionPrompt.Copied; copied.Stop(); copied.Start(); }
        catch (Exception error) when (error is InvalidOperationException or OutOfMemoryException) { copy.Content = "Could not copy"; copied.Stop(); copied.Start(); }
    }

    void Reveal(IntPtr anchor)
    {
        if (!IsVisible) Show();
        Place(anchor);
        watch.Start();
    }

    /// Beside the recording control when there is one; otherwise above the tray corner of the main display.
    void Place(IntPtr anchor)
    {
        if (Handle == IntPtr.Zero) return;
        var screens = System.Windows.Forms.Screen.AllScreens;
        var display = (anchor != IntPtr.Zero ? System.Windows.Forms.Screen.FromHandle(anchor) : System.Windows.Forms.Screen.PrimaryScreen ?? screens[0]).WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(this);
        double room = display.Width / dpi.DpiScaleX - 2 * Gap;
        if (Width > room) Width = Math.Max(160 + 2 * ShadowMargin, room);
        UpdateLayout();
        if (!Native.GetWindowRect(Handle, out var bounds)) return;
        double width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
        double x, y;
        if (anchor != IntPtr.Zero && Native.GetWindowRect(anchor, out var at)) {
            (x, y) = LivePreviewPlacement.Place(screens.Select(screen => new WorkArea(screen.WorkingArea.X, screen.WorkingArea.Y, screen.WorkingArea.Width, screen.WorkingArea.Height)).ToArray(),
                new WorkArea(at.Left, at.Top, at.Right - at.Left, at.Bottom - at.Top), width, height, Gap * dpi.DpiScaleY);
        } else { x = display.Right - width - Gap * dpi.DpiScaleX; y = display.Bottom - height - Gap * dpi.DpiScaleY; }
        Native.SetWindowPos(Handle, IntPtr.Zero, (int)Math.Round(x), (int)Math.Round(y), 0, 0, 0x15);
    }
}
