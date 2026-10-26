using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PFlow.Core;

namespace PFlow.Windows;

/// Wheel and precision-touchpad scrolling of the Settings pages. One notch (delta 120) moves 48 px,
/// Windows' three lines of 16, and glides there over 150 ms with an ease-out (ScrollGlide), one
/// offset per rendered frame; notches in quick succession add up. A touchpad's small deltas move
/// the page in proportion as they arrive, with no glide (they are already smooth). WPF's own
/// ScrollViewer jumped the full three lines for every event however small its delta (0.1.24), and
/// 0.1.25 jumped 48 px in one frame per notch: both read as choppy. The box under the pointer takes
/// the wheel while it can still move that way; otherwise the page does. Touch panning is not
/// touched (it is manipulation, not the wheel); a finger, the scroll bar, a click, a key or closing the
/// window stops every glide on the page, a text box's included, and a touchpad delta during a glide
/// moves the page at once while the rest of the notch keeps gliding.
/// Moving the offset re-arranges only the page's content at its new place; nothing is re-measured.
internal static class SmoothScroll
{
    public const double PixelsPerNotch = 48;
    /// Pixels the wheel moves the content for one event: down for a negative delta.
    public static double Pixels(int delta) => -delta / 120.0 * PixelsPerNotch;
    static readonly ConditionalWeakTable<ScrollViewer, Glider> gliders = new();
    public static void Attach(ScrollViewer page)
    {
        page.CanContentScroll = false; page.IsDeferredScrollingEnabled = false;
        page.PreviewMouseWheel += (_, e) => {
            if (e.Handled || e.Delta == 0) return;
            var target = Target(page, e.OriginalSource as DependencyObject, e.Delta);
            if (target == null) return;
            Wheel(target, e.Delta); e.Handled = true;
        };
        // A key, a click (the scroll bar too), a finger or the window closing stops every glide on the page, a text box's included.
        void Release(object? sender, EventArgs e) => StopAll(page);
        page.PreviewMouseDown += Release; page.PreviewKeyDown += Release; page.PreviewTouchDown += Release; page.PreviewStylusDown += Release;
        page.ManipulationStarted += Release; page.Unloaded += Release;
    }
    /// Stops the glides of `page` and of every box inside it.
    internal static void StopAll(ScrollViewer page)
    {
        foreach (var glider in Glider.Running.ToArray())
            if (glider.Viewer == page || glider.Viewer.IsDescendantOf(page)) glider.Stop();
    }
    /// One wheel event on a viewer: a notch glides, a high-resolution delta moves at once.
    internal static void Wheel(ScrollViewer viewer, int delta)
    {
        var glider = gliders.GetValue(viewer, v => new Glider(v));
        if (ScrollGlide.IsNotch(delta)) glider.Notch(Pixels(delta));
        // A touchpad delta during a glide moves the page at once; the rest of the notch keeps gliding.
        else if (glider.Active) glider.Nudge(Pixels(delta));
        else viewer.ScrollToVerticalOffset(viewer.VerticalOffset + Pixels(delta));
    }
    /// True while a notch is still gliding on this viewer (the checks wait on it).
    internal static bool Gliding(ScrollViewer viewer) => gliders.TryGetValue(viewer, out var glider) && glider.Active;
    /// Which viewer takes this wheel event: the nearest pixel-scrolling box under the pointer that
    /// can still move that way, else the page when it can, else nothing (the event goes on as it is;
    /// a box that scrolls by whole items keeps WPF's own stepping).
    internal static ScrollViewer? Target(ScrollViewer page, DependencyObject? source, int delta)
    {
        for (var node = source; node != null && node != page; node = Parent(node))
            if (node is ScrollViewer inner) {
                if (ScrollsByItems(inner)) return null;
                if (CanTake(inner, delta)) return inner;
            }
        return CanTake(page, delta) ? page : null;
    }
    /// A list's viewer steps by whole items (its offsets are item counts); a text box's viewer also
    /// reports CanContentScroll but its offsets are pixels, so it is scrolled by pixel like the page.
    internal static bool ScrollsByItems(ScrollViewer viewer) => viewer.CanContentScroll && viewer.TemplatedParent is not System.Windows.Controls.Primitives.TextBoxBase;
    static bool CanTake(ScrollViewer viewer, int delta) => delta < 0 ? viewer.VerticalOffset < viewer.ScrollableHeight - 0.5 : viewer.VerticalOffset > 0.5;
    static DependencyObject? Parent(DependencyObject node) => node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);

    /// One viewer's glide, stepped once per rendered frame and unhooked when it ends, so an idle
    /// page costs nothing. A 15 ms timer steps it too: where Windows paces no frames for WPF (no
    /// display refresh to follow, as on the test VM) the glide still moves at about 60 steps a second;
    /// both read the same clock, so a step that lands twice changes nothing. Offsets land on whole
    /// device pixels, so text does not shimmer mid-glide.
    sealed class Glider
    {
        /// Gliders with a glide under way (held only while they run).
        internal static readonly HashSet<Glider> Running = [];
        readonly ScrollViewer viewer;
        internal ScrollViewer Viewer => viewer;
        readonly ScrollGlide glide = new();
        readonly System.Windows.Threading.DispatcherTimer ticks;
        static readonly Stopwatch clock = Stopwatch.StartNew();
        bool hooked;
        internal Glider(ScrollViewer viewer)
        {
            this.viewer = viewer;
            ticks = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Render, viewer.Dispatcher) { Interval = TimeSpan.FromMilliseconds(15) };
            ticks.Tick += (_, _) => Step();
        }
        internal bool Active => glide.Active;
        internal void Notch(double pixels)
        {
            glide.Add(viewer.VerticalOffset, pixels, viewer.ScrollableHeight, clock.Elapsed.TotalMilliseconds);
            if (!hooked) { hooked = true; Running.Add(this); CompositionTarget.Rendering += Frame; ticks.Start(); }
            Step();
        }
        internal void Nudge(double pixels) { glide.Shift(pixels, viewer.ScrollableHeight); Step(); }
        internal void Stop() { glide.Stop(); Unhook(); }
        void Unhook() { if (hooked) { hooked = false; Running.Remove(this); CompositionTarget.Rendering -= Frame; ticks.Stop(); } }
        void Frame(object? sender, EventArgs e) => Step();
        void Step()
        {
            if (!hooked) return;
            double offset = glide.At(clock.Elapsed.TotalMilliseconds), scale = VisualTreeHelper.GetDpi(viewer).DpiScaleY;
            viewer.ScrollToVerticalOffset(Math.Round(offset * scale) / scale);
            if (!glide.Active) Unhook();
        }
    }
}
