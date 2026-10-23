using PFlow.Core;

// The smooth wheel scroll's arithmetic (ScrollGlide): notches glide and add up, touchpad deltas do not glide.
internal static class ScrollGlideChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static void Run()
    {
        passed = 0;
        Check("a wheel notch is a whole multiple of 120; a touchpad's small or odd delta is not",
            ScrollGlide.IsNotch(-120) && ScrollGlide.IsNotch(240) && !ScrollGlide.IsNotch(-30) && !ScrollGlide.IsNotch(8) && !ScrollGlide.IsNotch(130) && !ScrollGlide.IsNotch(0));
        Check("the ease-out starts at 0, ends at 1, never goes back and is past half-way by a third of the time",
            ScrollGlide.Ease(0) == 0 && ScrollGlide.Ease(1) == 1 && ScrollGlide.Ease(2) == 1 && ScrollGlide.Ease(1 / 3.0) > .5
            && Enumerable.Range(0, 100).All(i => ScrollGlide.Ease((i + 1) / 100.0) >= ScrollGlide.Ease(i / 100.0)));
        var glide = new ScrollGlide();
        glide.Add(current: 0, pixels: 48, maximum: 1000, nowMs: 0);
        double first = glide.At(16), half = glide.At(75);
        Check("one notch does not jump: the first frame moves part of the way, half the time is most of the way",
            glide.Active && first > 0 && first < 24 && half > 36 && half < 48);
        Check($"the glide lands exactly on the notch after {ScrollGlide.DurationMs} ms and lets go", glide.At(ScrollGlide.DurationMs) == 48 && !glide.Active);
        glide.Add(0, 48, 1000, 0); double now = glide.At(40);
        glide.Add(now, 48, 1000, 40); glide.Add(glide.At(60), 48, 1000, 60);
        Check("notches during a glide add up: three quick notches go 144 px, starting from where the page is", glide.To == 144 && glide.From > 0 && glide.At(60 + ScrollGlide.DurationMs) == 144);
        glide.Add(990, 48, 1000, 0);
        Check("a glide never heads past the end of the page", glide.To == 1000 && glide.At(1000) == 1000);
        glide.Add(10, -48, 1000, 0);
        Check("or above its top", glide.To == 0);
        glide.Add(0, 48, 1000, 0); glide.Stop();
        Check("something else moving the page stops the glide", !glide.Active);
        Console.WriteLine($"{passed} scroll glide checks passed.");
    }
}
