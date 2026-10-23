using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

internal static partial class Program
{
    /// A finger for the touch check: WPF's TouchDevice with a fixed point.
    sealed class FictionalTouch(int id) : TouchDevice(id)
    {
        public override TouchPoint GetTouchPoint(IInputElement? relativeTo) => new(this, new Point(10, 10), new Rect(10, 10, 1, 1), TouchAction.Down);
        public override TouchPointCollection GetIntermediateTouchPoints(IInputElement? relativeTo) => [];
    }

    /// The 0.1.26 review: a key, the scroll bar, a finger or closing the window must stop every glide on the
    /// page (a text box's too), and a touchpad delta mid-glide must carry the rest of the notch.
    static void GlideStops()
    {
        (ScrollViewer Page, ScrollViewer Box, TextBox Text, Window Window) Open()
        {
            var box = new TextBox { Text = string.Join("\n", Enumerable.Range(1, 120).Select(i => "fictional line " + i)), Height = 80, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Visible };
            var stack = new StackPanel(); stack.Children.Add(box); for (int i = 0; i < 200; i++) stack.Children.Add(new TextBlock { Text = "filler " + i });
            var page = SettingsWindow.Scroll(stack); var window = new Window { Width = 320, Height = 260, Content = page, ShowActivated = false };
            window.Show(); window.UpdateLayout(); Drain();
            return (page, Descendants<ScrollViewer>(box).First(), box, window);
        }
        bool Start(ScrollViewer page, ScrollViewer box) { SmoothScroll.Wheel(page, -240); SmoothScroll.Wheel(box, -240); return SmoothScroll.Gliding(page) && SmoothScroll.Gliding(box); }
        void Settle(ScrollViewer viewer) { for (var wait = System.Diagnostics.Stopwatch.StartNew(); SmoothScroll.Gliding(viewer) && wait.ElapsedMilliseconds < 3000;) { Drain(); System.Threading.Thread.Sleep(5); } }
        var cases = new (string Name, Action<(ScrollViewer Page, ScrollViewer Box, TextBox Text, Window Window)> Act)[] {
            ("PageDown", v => v.Text.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(v.Text)!, 0, Key.PageDown) { RoutedEvent = Keyboard.PreviewKeyDownEvent })),
            ("a scroll bar drag", v => Descendants<System.Windows.Controls.Primitives.Thumb>(v.Page).Last().RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = Mouse.PreviewMouseDownEvent })),
            ("a touch pan", v => v.Text.RaiseEvent(new TouchEventArgs(new FictionalTouch(7), 0) { RoutedEvent = UIElement.PreviewTouchDownEvent })),
            ("closing the window", v => v.Window.Close()),
        };
        foreach (var (name, act) in cases) {
            var view = Open();
            try {
                bool started = Start(view.Page, view.Box);
                act(view); Drain();
                Check($"{name} stops the page's glide and the text box's", started && !SmoothScroll.Gliding(view.Page) && !SmoothScroll.Gliding(view.Box));
            } finally { if (view.Window.IsLoaded) view.Window.Close(); }
        }
        {
            var view = Open();
            try {
                SmoothScroll.Wheel(view.Page, -120); double before = view.Page.VerticalOffset;
                SmoothScroll.Wheel(view.Page, -30); view.Page.UpdateLayout(); double after = view.Page.VerticalOffset; bool still = SmoothScroll.Gliding(view.Page);
                Settle(view.Page); view.Page.UpdateLayout();
                Check($"a touchpad delta mid-glide moves at once ({before:F0} -> {after:F0} px) and the notch still lands: {view.Page.VerticalOffset:F0} px = 48 + 12",
                    still && after - before >= 11 && Math.Abs(view.Page.VerticalOffset - 60) < 1);
            } finally { view.Window.Close(); }
        }
    }

    /// Settings pages scroll by pixel in proportion to the wheel's delta (SmoothScroll): a notch is
    /// 48 px (gliding there), a touchpad's quarter notch 12 px, and a box under the pointer takes the wheel only while
    /// it can still move that way. The scripted scroll prints its frame numbers.
    static void NativeScroll()
    {
        Check("one notch moves 48 px down, a touchpad's quarter notch 12, a notch up 48 up", SmoothScroll.Pixels(-120) == 48 && SmoothScroll.Pixels(-30) == 12 && SmoothScroll.Pixels(120) == -48);
        var frames = ScrollFrames(true);
        Check("40 touchpad events of a quarter notch move the page 480 px, not 1920", Math.Abs(frames.SmallMoved - 480) < 1);
        Check("10 notches move the page 480 px", Math.Abs(frames.NotchMoved - 480) < 1);
        // One notch glides instead of jumping: right after the event the page has not moved the whole notch;
        // once the glide's frames have run it has. A touchpad delta moves at once.
        {
            var filler = new StackPanel(); for (int i = 0; i < 200; i++) filler.Children.Add(new TextBlock { Text = "filler " + i });
            var glidePage = SettingsWindow.Scroll(filler); var glideWindow = new Window { Width = 300, Height = 240, Content = glidePage, ShowActivated = false };
            try {
                glideWindow.Show(); glideWindow.UpdateLayout(); Drain();
                SmoothScroll.Wheel(glidePage, -120); glidePage.UpdateLayout(); double right = glidePage.VerticalOffset; bool gliding = SmoothScroll.Gliding(glidePage);
                for (var wait = System.Diagnostics.Stopwatch.StartNew(); SmoothScroll.Gliding(glidePage) && wait.ElapsedMilliseconds < 3000;) { Drain(); System.Threading.Thread.Sleep(5); }
                glidePage.UpdateLayout();
                Check($"a notch glides: {right:F0} px at once, {glidePage.VerticalOffset:F0} px when it lands", gliding && right < 48 && Math.Abs(glidePage.VerticalOffset - 48) < 1);
                double at = glidePage.VerticalOffset; SmoothScroll.Wheel(glidePage, -30); glidePage.UpdateLayout();
                Check("a touchpad's quarter notch moves 12 px at once, with no glide", Math.Abs(glidePage.VerticalOffset - at - 12) < 1 && !SmoothScroll.Gliding(glidePage));
            } finally { glideWindow.Close(); }
        }
        GlideStops();
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
