using PFlow.Windows;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

internal static partial class Program
{
    /// The tray icon: the frame matches the taskbar's DPI (16/20/24/32/40/48 px at 100-300%), the
    /// talking-pig mark fills it (opaque box at least 80% of the width at 16 and 24 px, waves included),
    /// and the light/dark choice follows the taskbar. PFLOW_SHOTS=<folder> writes
    /// tray-{dark,light}-{100,150,200}.png beside Windows' own volume and network icons.
    static void NativeTray()
    {
        _ = System.Windows.Application.Current ?? new System.Windows.Application { ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown }; // pack:// URIs need the application
        Check("frame by DPI: 16 at 100%, 20 at 125%, 24 at 150%, 32 at 200%, 40 at 250%, 48 at 300%, never beyond", TrayIcon.SizeFor(96) == 16 && TrayIcon.SizeFor(120) == 20 && TrayIcon.SizeFor(144) == 24
            && TrayIcon.SizeFor(192) == 32 && TrayIcon.SizeFor(240) == 40 && TrayIcon.SizeFor(288) == 48 && TrayIcon.SizeFor(384) == 48 && TrayIcon.SizeFor(72) == 16);
        Check("a light taskbar gets the dark head, a dark taskbar the light head", TrayIcon.FileFor(true) == "TrayOnLight.ico" && TrayIcon.FileFor(false) == "TrayOnDark.ico");
        foreach (bool light in new[] { false, true }) foreach (int dpi in new[] { 96, 120, 144, 192, 240, 288 }) {
            using var icon = TrayIcon.Load(dpi, light);
            Check($"{(light ? "light" : "dark")} taskbar at {dpi} dpi loads the {TrayIcon.SizeFor(dpi)} px frame", icon.Width == TrayIcon.SizeFor(dpi) && icon.Height == TrayIcon.SizeFor(dpi));
        }
        foreach (bool light in new[] { false, true }) foreach (int dpi in new[] { 96, 144 }) {
            using var icon = TrayIcon.Load(dpi, light); using var bitmap = icon.ToBitmap();
            int size = bitmap.Width, left = size, right = -1, waves = 0;
            for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
                var p = bitmap.GetPixel(x, y);
                if (p.A <= 128) continue;
                left = Math.Min(left, x); right = Math.Max(right, x);
                // The sound waves: lilac pixels in the right quarter.
                if (x >= size * 3 / 4 && p.B > 200 && p.R > 140 && p.G < p.B) waves++;
            }
            int covered = right - left + 1;
            Check($"{(light ? "light" : "dark")} taskbar, {size} px: the mark's opaque box covers {covered} of {size} px across (at least 80%), with its sound waves ({waves} px)",
                covered * 100 >= size * 80 && waves >= 2);
        }
        // W028: the dark-taskbar icon has a light rim around the head; the light-taskbar one has none.
        foreach (int dpi in new[] { 96, 144 }) {
            int Rim(bool light) {
                using var icon = TrayIcon.Load(dpi, light); using var bitmap = icon.ToBitmap(); int count = 0;
                for (int y = 0; y < bitmap.Height; y++) for (int x = 0; x < bitmap.Width; x++) { var p = bitmap.GetPixel(x, y); if (p.A > 128 && p.R > 200 && p.G > 200 && p.B > 200 && Math.Abs(p.R - p.B) < 20) count++; }
                return count;
            }
            int dark = Rim(false), light = Rim(true);
            Check($"dark taskbar, {TrayIcon.SizeFor(dpi)} px: a light rim keeps the dark head readable ({dark} rim px; light-taskbar icon {light})", dark >= TrayIcon.SizeFor(dpi) && light <= 2);
        }
        // The app, Start and Installed-apps icon is the original mark again, every frame (as first published).
        using (var original = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/pFlow;component/Assets/Pesh.ico")).Stream)
            Check("Pesh.ico is the original talking-pig icon, byte for byte", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(original)) == "ADD7F361CB15AA8AC2007D179AF97B828C8D79C6B06B5493A37BA1BB6BB6D5DA");
        int taskbar = TrayIcon.TaskbarDpi();
        using (var current = TrayIcon.Current())
            Check($"the icon in use matches this taskbar's DPI ({taskbar})", taskbar >= 96 && taskbar <= 384 && current.Width == TrayIcon.SizeFor(taskbar));
        Check("the taskbar theme is read without error", TrayIcon.LightTaskbar() is bool);
        // PFLOW_SHOTS: the tray icon at 100/150/200% on a light and a dark taskbar, between the volume and
        // network icons as Windows 11 draws them (Segoe Fluent Icons), at real size and blown up 3x.
        if (Environment.GetEnvironmentVariable("PFLOW_SHOTS") is { } shots) foreach (int scale in new[] { 100, 150, 200 }) foreach (bool light in new[] { false, true }) {
            int dpi = 96 * scale / 100; using var icon = TrayIcon.Load(dpi, light); using var mark = icon.ToBitmap(); int size = icon.Width;
            var ink = light ? Color.Black : Color.White; var bar = light ? Color.FromArgb(0xF3, 0xF3, 0xF3) : Color.FromArgb(0x20, 0x20, 0x20);
            int slot = size * 2, height = 48 * scale / 100;
            using var real = new Bitmap(slot * 3, height);
            using (var g = Graphics.FromImage(real)) {
                g.Clear(bar); g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using var font = new Font("Segoe Fluent Icons", size * 0.75f, GraphicsUnit.Point);
                using var brush = new SolidBrush(ink);
                var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString("\uE767", font, brush, new RectangleF(0, 0, slot, height), format);
                g.DrawImage(mark, slot + (slot - size) / 2, (height - size) / 2, size, size);
                g.DrawString("\uE701", font, brush, new RectangleF(slot * 2, 0, slot, height), format);
            }
            using var strip = new Bitmap(real.Width * 4 + 24, real.Height * 3 + 8);
            using (var g = Graphics.FromImage(strip)) {
                g.Clear(bar); g.DrawImage(real, 4, 4, real.Width, real.Height);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor; g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
                g.DrawImage(real, real.Width + 16, 4, real.Width * 3, real.Height * 3);
            }
            strip.Save(Path.Combine(shots, $"tray-{(light ? "light" : "dark")}-{scale}.png"), ImageFormat.Png);
        }
    }
}
