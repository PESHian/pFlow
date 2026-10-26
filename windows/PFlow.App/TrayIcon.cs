using System.Drawing;
using System.Windows;
using Microsoft.Win32;

namespace PFlow.Windows;

/// The tray icon: the Pesh talking-pig mark (head and sound waves, as in Assets/Pesh.ico) with its
/// transparent margins cropped so head and waves fill the frame the taskbar's DPI asks for (16-48 px;
/// at 16-24 px the waves are two clean arcs, scripts/tray-icons.py). Assets/TrayOnDark.ico and
/// TrayOnLight.ico are the taskbar-theme choice and carry the same mark. The 0.1.24 icon was the whole
/// 256 px mark handed to Windows to shrink (a 9 px head); 0.1.25-0.1.26 used a plain head without the
/// waves, which the owner did not want.
internal static class TrayIcon
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string className, string? windowName);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    public static readonly int[] Sizes = [16, 20, 24, 32, 40, 48];
    /// The frame for a taskbar DPI: 16 px at 100%, 20 at 125%, 24 at 150%, 32 at 200%, 40 at 250%, 48 at 300%.
    public static int SizeFor(int dpi) => Math.Clamp((int)Math.Round(16 * dpi / 96.0), 16, 48);
    public static string FileFor(bool lightTaskbar) => lightTaskbar ? "TrayOnLight.ico" : "TrayOnDark.ico";
    /// The taskbar's own DPI (the tray sits on the primary taskbar), else the system DPI.
    public static int TaskbarDpi()
    {
        var taskbar = FindWindow("Shell_TrayWnd", null);
        uint dpi = taskbar != IntPtr.Zero ? GetDpiForWindow(taskbar) : 0;
        return (int)(dpi > 0 ? dpi : GetDpiForSystem());
    }
    /// Windows paints the taskbar light when the system theme is light (SystemUsesLightTheme = 1).
    public static bool LightTaskbar()
    {
        try {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int light && light == 1;
        } catch (Exception error) when (error is System.Security.SecurityException or IOException or UnauthorizedAccessException) { return false; }
    }
    public static Icon Load(int dpi, bool lightTaskbar)
    {
        int size = SizeFor(dpi);
        var resource = Application.GetResourceStream(new Uri("pack://application:,,,/pFlow;component/Assets/" + FileFor(lightTaskbar)));
        using var stream = resource.Stream;
        return new Icon(stream, new System.Drawing.Size(size, size));
    }
    /// The icon for this taskbar right now; called again when the display or the theme changes.
    public static Icon Current() => Load(TaskbarDpi(), LightTaskbar());
}
