using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace PFlow.Windows;

internal sealed class Capsule : Window
{
    readonly Border shell;
    readonly WaveView wave;
    readonly Button record;
    readonly StateStore store;
    bool rendering;
    long lastFrame;
    internal bool Animating => rendering;
    Native.PointerPoint dragStart;
    Native.WindowBounds dragBounds;
    bool dragReady, dragging, canToggle = true;
    public event Action? OpenSettings;
    public event Action? Cancel;
    public event Action? ToggleRecording;
    public event Action? OpenHistory;
    public Func<double>? AudioLevel;
    public IntPtr Handle => new WindowInteropHelper(this).Handle;
    /// Superwhisper's recording pill as measured on Windows (W028): 62 x 34 DIP outside its 1 px outline, fully round.
    internal const double CapsuleWidth = 62, CapsuleHeight = 34, OutlineOpacity = .65;
    /// Superwhisper's pill material: no blur or system backdrop (its window has none), a near-black fill at 86%
    /// (measured over white and over dark grey: #121212, alpha 220), so what is behind shows through a little.
    internal static readonly Color Fill = Color.FromArgb(220, 0x12, 0x12, 0x12);
    /// The waveform's room inside the outline: 30 x 16 DIP, about Superwhisper's (22 x 16) with a little more width.
    internal static readonly Thickness WavePadding = new(15, 8, 15, 8);
    internal Border Shell => shell;
    internal WaveView Wave => wave;
    public Capsule(StateStore store)
    {
        this.store = store; Width = CapsuleWidth; Height = CapsuleHeight; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        shell = new Border { CornerRadius = new CornerRadius(CapsuleHeight / 2), BorderThickness = new Thickness(1), Padding = new Thickness(0), Background = new SolidColorBrush(Fill) };
        wave = new WaveView { IsHitTestVisible = false };
        var template = new ControlTemplate(typeof(Button));
        var surface = new FrameworkElementFactory(typeof(Border)); surface.SetValue(Border.BackgroundProperty, Brushes.Transparent); surface.SetValue(Border.PaddingProperty, new Thickness(WavePadding.Left, WavePadding.Top, WavePadding.Right, WavePadding.Bottom));
        surface.AppendChild(new FrameworkElementFactory(typeof(ContentPresenter))); template.VisualTree = surface;
        record = new Button { Content = wave, Focusable = false, IsTabStop = false, Template = template, Cursor = Cursors.Hand, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
        record.Click += (_, _) => { if (canToggle && !dragging) ToggleRecording?.Invoke(); };
        record.PreviewMouseLeftButtonDown += (_, _) => {
            dragging = false;
            dragReady = Native.GetPhysicalCursorPos(out dragStart) && Native.GetWindowRect(Handle, out dragBounds);
        };
        record.PreviewMouseMove += (_, e) => {
            if (e.LeftButton != MouseButtonState.Pressed || !dragReady || !Native.GetPhysicalCursorPos(out var point)) return;
            int dx = point.X - dragStart.X, dy = point.Y - dragStart.Y; var dpi = VisualTreeHelper.GetDpi(this);
            if (!dragging && Math.Abs(dx) < SystemParameters.MinimumHorizontalDragDistance * dpi.DpiScaleX && Math.Abs(dy) < SystemParameters.MinimumVerticalDragDistance * dpi.DpiScaleY) return;
            dragging = true;
            // Move in physical pixels without activating the overlay or changing its size/z-order.
            Native.SetWindowPos(Handle, IntPtr.Zero, dragBounds.Left + dx, dragBounds.Top + dy, 0, 0, 0x15);
            e.Handled = true;
        };
        record.PreviewMouseLeftButtonUp += (_, _) => {
            dragReady = false;
            if (dragging) Place(true);
        };
        record.LostMouseCapture += (_, _) => { if (dragReady && dragging) Place(true); dragReady = false; };
        shell.Child = record; Content = shell;
        var menu = new ContextMenu(); var settings = new MenuItem { Header = "Settings" }; settings.Click += (_, _) => OpenSettings?.Invoke(); menu.Items.Add(settings);
        var history = new MenuItem { Header = "History" }; history.Click += (_, _) => OpenHistory?.Invoke(); menu.Items.Add(history);
        var center = new MenuItem { Header = "Center at bottom" }; center.Click += (_, _) => ResetPosition(); menu.Items.Add(center);
        var cancel = new MenuItem { Header = "Cancel recording" }; cancel.Click += (_, _) => Cancel?.Invoke(); menu.Items.Add(cancel); ContextMenu = menu;
        SourceInitialized += (_, _) => {
            Native.SetWindowLongPtr(Handle, -20, (IntPtr)(Native.GetWindowLongPtr(Handle, -20).ToInt64() | 0x08000000 | 0x80));
            HwndSource.FromHwnd(Handle)?.AddHook((IntPtr hwnd, int msg, IntPtr wp, IntPtr lp, ref bool handled) => { if (msg is 0x21 or 0x24B) { handled = true; return (IntPtr)3; } if ((msg == 0x2E0 || msg == 0x7E) && !dragReady && IsVisible) Dispatcher.BeginInvoke(new Action(() => Place())); return IntPtr.Zero; });
        };
        Loaded += (_, _) => Place();
        IsVisibleChanged += (_, _) => SyncAnimation();
        ApplyTheme(); Set(Phase.Idle);
    }
    internal void ResetPosition()
    {
        store.Preferences.CapsuleX = store.Preferences.CapsuleY = -1; store.Preferences.CapsulePositionVersion = 0; store.SavePreferences(); Place();
    }
    void Place(bool dragged = false)
    {
        if (Handle == IntPtr.Zero || !Native.GetWindowRect(Handle, out var bounds)) return;
        var screens = System.Windows.Forms.Screen.AllScreens;
        var preferred = System.Windows.Forms.Screen.FromHandle(Native.GetForegroundWindow());
        bool saved = dragged || store.Preferences.CapsulePositionVersion == 1 || store.Preferences.CapsuleX != -1 || store.Preferences.CapsuleY != -1;
        bool migrate = saved && !dragged && store.Preferences.CapsulePositionVersion == 0;
        if (migrate) { Left = store.Preferences.CapsuleX; Top = store.Preferences.CapsuleY; Native.GetWindowRect(Handle, out bounds); }
        double? x = saved ? dragged || migrate ? bounds.Left : store.Preferences.CapsuleX : null;
        double? y = saved ? dragged || migrate ? bounds.Top : store.Preferences.CapsuleY : null;
        var point = CapsulePlacement.Place(screens.Select(screen => new WorkArea(screen.WorkingArea.X, screen.WorkingArea.Y, screen.WorkingArea.Width, screen.WorkingArea.Height)).ToArray(),
            Array.FindIndex(screens, screen => screen.DeviceName == preferred.DeviceName), bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, x, y);
        Native.SetWindowPos(Handle, IntPtr.Zero, (int)Math.Round(point.X), (int)Math.Round(point.Y), 0, 0, 0x15);
        if (dragged || migrate) { store.Preferences.CapsuleX = point.X; store.Preferences.CapsuleY = point.Y; store.Preferences.CapsulePositionVersion = 1; store.SavePreferences(); }
    }
    void SyncAnimation()
    {
        bool animate = IsVisible && (wave.Active || wave.Processing);
        if (animate == rendering) return;
        rendering = animate;
        if (animate) { lastFrame = Stopwatch.GetTimestamp(); CompositionTarget.Rendering += Frame; }
        else CompositionTarget.Rendering -= Frame;
    }
    void Frame(object? sender, EventArgs e)
    {
        long now = Stopwatch.GetTimestamp(); double seconds = Stopwatch.GetElapsedTime(lastFrame, now).TotalSeconds; lastFrame = now;
        wave.Advance(AudioLevel?.Invoke() ?? 0, store.Preferences.Waveform, seconds);
    }
    /// Superwhisper's glass in every theme (a near-black fill at 86%, no blur), a 1 px outline in the accent at 65%
    /// (the owner's rule: the accent, never white), the waveform in the palette's ink, both lifted when too dark
    /// for black (PeshTheme.OnBlack); the same in every phase.
    public void ApplyTheme()
    {
        shell.Background = new SolidColorBrush(Fill);
        shell.BorderBrush = new SolidColorBrush(PeshTheme.OnBlack((Color)ColorConverter.ConvertFromString("#" + store.Preferences.Accent))) { Opacity = OutlineOpacity };
        wave.Color = PeshTheme.OnBlack(PeshTheme.Gradient(store.Preferences));
    }
    internal void Reveal() { Show(); Place(); Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => Place())); SyncAnimation(); }
    void HideControl() { Hide(); SyncAnimation(); }
    public void Set(Phase phase, string? detail = null)
    {
        bool wasActive = wave.Active;
        wave.Active = phase is Phase.Recording or Phase.Continuous;
        if (wave.Active && !wasActive) wave.Reset();
        wave.Processing = phase is Phase.Processing or Phase.Inserting;
        canToggle = !wave.Processing;
        System.Windows.Automation.AutomationProperties.SetName(this, "pFlow " + phase);
        System.Windows.Automation.AutomationProperties.SetHelpText(this, detail ?? phase.ToString());
        System.Windows.Automation.AutomationProperties.SetName(record, wave.Processing ? "Processing" : wave.Active ? "Stop recording" : "Start recording");
        if (wave.Active || wave.Processing) Reveal(); else HideControl();
    }
    protected override void OnClosed(EventArgs e) { CompositionTarget.Rendering -= Frame; rendering = false; base.OnClosed(e); }
}
internal sealed class WaveView : PeshDrawing
{
    internal readonly WaveMotion Motion = new();
    internal long Frames { get; private set; }
    public Brush Color { get => Ink; set => Ink = value; }
    public bool Active, Processing;
    double sweep;
    string style = "wave";
    public void Reset() { Motion.Reset(); sweep = 0; InvalidateVisual(); }
    public void Advance(double level, string style, double seconds)
    {
        Frames++; Motion.Advance(Active ? level : 0, seconds); this.style = style; sweep += Math.Clamp(seconds, 0, .25) * 2.6; InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var ink = CanvasInk(ActualWidth, ActualHeight);
        if (Processing) {
            double length = ActualWidth * .32, x = (ActualWidth - length) * (1 - Math.Cos(sweep)) / 2, y = ActualHeight / 2;
            dc.DrawLine(new Pen(ink, 2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, new Point(x, y), new Point(x + length, y)); return;
        }
        var levels = Motion.Levels(); double mid = ActualHeight / 2, peak = Math.Max(.25, levels.Max());
        // 0..1 of the take's own loudest moment, eased so quiet sounds still show and loud ones do not all max out.
        double Height(double value) => Math.Pow(Math.Clamp(value / peak, 0, 1), 1.4);
        if (style == "lines") {
            // One thin line through the latest levels, swinging up and down around the middle (an oscilloscope trace).
            int count = Math.Clamp((int)(ActualWidth / 2), 2, levels.Length); double step = ActualWidth / (count - 1), swing = mid - 1;
            var trace = new StreamGeometry();
            using (var path = trace.Open()) {
                for (int i = 0; i < count; i++) {
                    var point = new Point(i * step, mid + (i % 2 == 0 ? -1 : 1) * Height(levels[levels.Length - count + i]) * swing);
                    if (i == 0) path.BeginFigure(point, false, false); else path.LineTo(point, true, true);
                }
            }
            trace.Freeze();
            dc.DrawGeometry(null, new Pen(ink, 1.25) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, trace); return;
        }
        // The default: Superwhisper's bars, 2 DIP wide with 2 DIP gaps, as many as fit up to seven (Superwhisper shows six), each as tall as
        // the voice was at that moment, in the theme's gradient. Silence is a row of 2 x 2 dots.
        int bars = Math.Clamp((int)((ActualWidth + Gap) / (BarWidth + Gap)), 1, Math.Min(MostBars, levels.Length));
        double left = Math.Round((ActualWidth - (bars * (BarWidth + Gap) - Gap)) / 2);
        for (int i = 0; i < bars; i++) {
            double h = Math.Round(Math.Max(BarWidth, Height(levels[levels.Length - bars + i]) * ActualHeight) / 2) * 2;
            dc.DrawRoundedRectangle(ink, null, new Rect(left + i * (BarWidth + Gap), mid - h / 2, BarWidth, h), 1, 1);
        }
    }
    internal const double BarWidth = 2, Gap = 2;
    internal const int MostBars = 7;
}
