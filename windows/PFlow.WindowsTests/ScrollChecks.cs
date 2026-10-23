using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

internal static partial class Program
{
    /// Settings pages scroll by pixel in proportion to the wheel's delta (SmoothScroll): a notch is
    /// 48 px, a touchpad's quarter notch 12 px, and a box under the pointer takes the wheel only while
    /// it can still move that way. The scripted scroll prints its frame numbers.
    static void NativeScroll()
    {
        Check("one notch moves 48 px down, a touchpad's quarter notch 12, a notch up 48 up", SmoothScroll.Pixels(-120) == 48 && SmoothScroll.Pixels(-30) == 12 && SmoothScroll.Pixels(120) == -48);
        var frames = ScrollFrames(true);
        Check("40 touchpad events of a quarter notch move the page 480 px, not 1920", Math.Abs(frames.SmallMoved - 480) < 1);
        Check("10 notches move the page 480 px", Math.Abs(frames.NotchMoved - 480) < 1);
        // The target rule on a page with a short and a long text box under the pointer.
        var shortBox = new TextBox { Text = "one line", Height = 60, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var longBox = new TextBox { Text = string.Join("\n", Enumerable.Range(1, 80).Select(i => "fictional line " + i)), Height = 60, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var list = new ListBox { Height = 60, ItemsSource = Enumerable.Range(1, 40).Select(i => "item " + i).ToList() };
        var stack = new StackPanel(); stack.Children.Add(shortBox); stack.Children.Add(longBox); stack.Children.Add(list);
        for (int i = 0; i < 60; i++) stack.Children.Add(new TextBlock { Text = "filler " + i });
        var page = SettingsWindow.Scroll(stack);
        var window = new Window { Width = 300, Height = 240, Content = page, ShowActivated = false };
        try {
            window.Show(); window.UpdateLayout(); Drain();
            ScrollViewer? Inner(TextBox box) => Descendants<ScrollViewer>(box).FirstOrDefault();
            Check("a wheel over a text box with nothing to scroll goes to the page", SmoothScroll.Target(page, Descendants<FrameworkElement>(shortBox).Last(), -30) == page);
            Check("a wheel over a text box with more text scrolls the box, pixel by pixel", SmoothScroll.Target(page, Descendants<FrameworkElement>(longBox).Last(), -30) == Inner(longBox) && !SmoothScroll.ScrollsByItems(Inner(longBox)!));
            Inner(longBox)!.ScrollToBottom(); longBox.UpdateLayout(); Drain();
            Check("at the end of the box the wheel moves the page instead", SmoothScroll.Target(page, Descendants<FrameworkElement>(longBox).Last(), -30) == page);
            Check("a list that scrolls by whole items keeps its own stepping", SmoothScroll.Target(page, Descendants<FrameworkElement>(list).Last(), -30) == null && SmoothScroll.ScrollsByItems(Descendants<ScrollViewer>(list).First()));
            page.ScrollToBottom(); page.UpdateLayout(); Drain();
            Check("at the bottom of the page a wheel down has nowhere to go and is left alone", SmoothScroll.Target(page, Descendants<FrameworkElement>(shortBox).Last(), -30) == null && SmoothScroll.Target(page, Descendants<FrameworkElement>(shortBox).Last(), 30) == page);
        } finally { window.Close(); }
    }
}
