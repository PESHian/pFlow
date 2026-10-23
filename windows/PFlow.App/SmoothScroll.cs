using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PFlow.Windows;

/// Wheel and precision-touchpad scrolling of the Settings pages, pixel by pixel. One notch (delta
/// 120) moves 48 px, Windows' three lines of 16, and a touchpad's small deltas move in proportion:
/// WPF's own ScrollViewer moves the full three lines for every wheel event however small its
/// delta, so a touchpad's stream of tiny deltas raced down the page in 48 px jumps (what the owner
/// saw as jittery). The box under the pointer takes the wheel while it can still move that way;
/// otherwise the page does. Touch panning is not touched (it is manipulation, not the wheel).
internal static class SmoothScroll
{
    public const double PixelsPerNotch = 48;
    /// Pixels the wheel moves the content for one event: down for a negative delta.
    public static double Pixels(int delta) => -delta / 120.0 * PixelsPerNotch;
    public static void Attach(ScrollViewer page)
    {
        page.CanContentScroll = false; page.IsDeferredScrollingEnabled = false;
        page.PreviewMouseWheel += (_, e) => {
            if (e.Handled || e.Delta == 0) return;
            var target = Target(page, e.OriginalSource as DependencyObject, e.Delta);
            if (target == null) return;
            target.ScrollToVerticalOffset(target.VerticalOffset + Pixels(e.Delta)); e.Handled = true;
        };
    }
    /// Which viewer takes this wheel event: the nearest pixel-scrolling box under the pointer that
    /// can still move that way, else the page when it can, else nothing (the event goes on as it is;
    /// a box that scrolls by whole items keeps WPF's own stepping).
    internal static ScrollViewer? Target(ScrollViewer page, DependencyObject? source, int delta)
    {
        for (var node = source; node != null && node != page; node = Parent(node))
            if (node is ScrollViewer inner) {
                if (inner.CanContentScroll) return null;
                if (CanTake(inner, delta)) return inner;
            }
        return CanTake(page, delta) ? page : null;
    }
    static bool CanTake(ScrollViewer viewer, int delta) => delta < 0 ? viewer.VerticalOffset < viewer.ScrollableHeight - 0.5 : viewer.VerticalOffset > 0.5;
    static DependencyObject? Parent(DependencyObject node) => node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
}
