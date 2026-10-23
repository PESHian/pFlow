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
    internal const double CapsuleWidth = 96, CapsuleHeight = 26, OutlineOpacity = .65;
    internal Border Shell => shell;
    internal WaveView Wave => wave;
    public Capsule(StateStore store)
    {
        this.store = store; Width = CapsuleWidth; Height = CapsuleHeight; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        shell = new Border { CornerRadius = new CornerRadius(CapsuleHeight / 2), BorderThickness = new Thickness(1), Padding = new Thickness(0), Background = Brushes.Black };
        wave = new WaveView { IsHitTestVisible = false };
        var template = new ControlTemplate(typeof(Button));
        var surface = new FrameworkElementFactory(typeof(Border)); surface.SetValue(Border.BackgroundProperty, Brushes.Transparent); surface.SetValue(Border.PaddingProperty, new Thickness(8, 4, 8, 4));
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
    /// Solid black in every theme (no acrylic, no blur), a 1 px outline in the accent at 65%, the
    /// waveform in the palette's ink, both lifted when too dark for black (PeshTheme.OnBlack);
    /// the same in every phase. Matches the Mac capsule (96 x 26 pt).
    public void ApplyTheme()
    {
        shell.Background = Brushes.Black;
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
        var levels = Motion.Levels(); double spacing = ActualWidth / levels.Length, mid = ActualHeight / 2, peak = Math.Max(.25, levels.Max());
        double Amplitude(double value) => Math.Max(.6, Math.Pow(Math.Clamp(value / peak, 0, 1), 1.6) * .9 * mid);
        if (style == "lines") {
            var pen = new Pen(ink, Math.Min(2, spacing * .65)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
            for (int i = 0; i < levels.Length; i++) { double x = (i + .5) * spacing, h = Amplitude(levels[i]); dc.DrawLine(pen, new Point(x, mid - h), new Point(x, mid + h)); } return;
        }
        var points = levels.Select((value, i) => new Point((i + .5) * spacing, mid - Amplitude(value))).ToArray();
        var shape = new StreamGeometry();
        using (var path = shape.Open()) {
            path.BeginFigure(new Point(0, mid), true, true);
            for (int i = 0; i < points.Length; i++) { var next = i + 1 < points.Length ? points[i + 1] : new Point(ActualWidth, mid); path.QuadraticBezierTo(points[i], new Point((points[i].X + next.X) / 2, (points[i].Y + next.Y) / 2), true, false); }
            path.LineTo(new Point(ActualWidth, mid), true, false);
            for (int i = points.Length - 1; i >= 0; i--) { var point = new Point(points[i].X, 2 * mid - points[i].Y); var next = i > 0 ? new Point(points[i - 1].X, 2 * mid - points[i - 1].Y) : new Point(0, mid); path.QuadraticBezierTo(point, new Point((point.X + next.X) / 2, (point.Y + next.Y) / 2), true, false); }
        }
        dc.DrawGeometry(ink, new Pen(new SolidColorBrush(System.Windows.Media.Color.FromArgb(128, 0, 0, 0)), .75), shape);
    }
}
