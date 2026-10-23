using PFlow.Windows;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

internal static partial class Program
{
    /// The tray icon: the frame matches the taskbar's DPI (16/20/24/32/40/48 px at 100-300%), each
    /// variant is a solid silhouette at 16 px (not a shrunken mark), and the light/dark choice follows
    /// the taskbar. PFLOW_SHOTS=<folder> writes tray-{dark,light}-{100,150,200}.png: the icon at its
    /// real size on a taskbar-coloured strip next to a 3x blow-up, to look at.
    static void NativeTray()
    {
        Check("frame by DPI: 16 at 100%, 20 at 125%, 24 at 150%, 32 at 200%, 40 at 250%, 48 at 300%, never beyond", TrayIcon.SizeFor(96) == 16 && TrayIcon.SizeFor(120) == 20 && TrayIcon.SizeFor(144) == 24
            && TrayIcon.SizeFor(192) == 32 && TrayIcon.SizeFor(240) == 40 && TrayIcon.SizeFor(288) == 48 && TrayIcon.SizeFor(384) == 48 && TrayIcon.SizeFor(72) == 16);
        Check("a light taskbar gets the dark head, a dark taskbar the light head", TrayIcon.FileFor(true) == "TrayOnLight.ico" && TrayIcon.FileFor(false) == "TrayOnDark.ico");
        foreach (bool light in new[] { false, true }) foreach (int dpi in new[] { 96, 120, 144, 192, 240, 288 }) {
            using var icon = TrayIcon.Load(dpi, light);
            Check($"{(light ? "light" : "dark")} taskbar at {dpi} dpi loads the {TrayIcon.SizeFor(dpi)} px frame", icon.Width == TrayIcon.SizeFor(dpi) && icon.Height == TrayIcon.SizeFor(dpi));
        }
        foreach (bool light in new[] { false, true }) {
            using var icon = TrayIcon.Load(96, light); using var bitmap = icon.ToBitmap();
            int opaque = 0, bright = 0;
            for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) { var p = bitmap.GetPixel(x, y); if (p.A > 128) { opaque++; if (p.GetBrightness() > 0.6) bright++; } }
            // A solid head fills most of the 16 px box; the light head is mostly bright, the dark one mostly not.
            Check($"the 16 px {(light ? "dark" : "light")} head is a solid silhouette ({opaque} of 256 px opaque, {bright} bright)", opaque >= 110 && (light ? bright < opaque / 3 : bright > opaque * 2 / 3));
        }
        int taskbar = TrayIcon.TaskbarDpi();
        using (var current = TrayIcon.Current())
            Check($"the icon in use matches this taskbar's DPI ({taskbar})", taskbar >= 96 && taskbar <= 384 && current.Width == TrayIcon.SizeFor(taskbar));
        Check("the taskbar theme is read without error", TrayIcon.LightTaskbar() is bool);
        if (Environment.GetEnvironmentVariable("PFLOW_SHOTS") is { } shots) foreach (int scale in new[] { 100, 150, 200 }) foreach (bool light in new[] { false, true }) {
            int dpi = 96 * scale / 100; using var icon = TrayIcon.Load(dpi, light); using var bitmap = icon.ToBitmap();
            int bar = 48 * scale / 100; using var strip = new Bitmap(bar * 6 + icon.Width * 3 + 40, Math.Max(bar, icon.Height * 3 + 8));
            using (var g = Graphics.FromImage(strip)) {
                g.Clear(light ? Color.FromArgb(0xF3, 0xF3, 0xF3) : Color.FromArgb(0x20, 0x20, 0x20));
                g.DrawImage(bitmap, 16, (strip.Height - icon.Height) / 2, icon.Width, icon.Height);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor; g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
                g.DrawImage(bitmap, 16 + icon.Width + 24, 4, icon.Width * 3, icon.Height * 3);
            }
            strip.Save(Path.Combine(shots, $"tray-{(light ? "light" : "dark")}-{scale}.png"), ImageFormat.Png);
        }
    }
}
