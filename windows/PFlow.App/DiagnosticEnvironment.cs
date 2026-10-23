using Microsoft.Win32;
using System.Runtime.Intrinsics.X86;

namespace PFlow.Windows;

/// The facts about this PC and this copy of pFlow that a diagnostic report starts with, and the
/// per-take facts about the app being dictated into. Names, numbers and yes/no only: never the user
/// name, the computer name, a path, a window title or any text.
internal static class DiagnosticEnvironment
{
    internal static IEnumerable<DiagField> Collect(Whisper whisper, StateStore store, string activationKey)
    {
        var fields = new List<DiagField>();
        void Add(string key, Func<object?> value)
        {
            try { fields.Add(new(key, value())); }
            catch (Exception error) { fields.Add(new(key, "unreadable (" + error.GetType().Name + ")")); }
        }
        Add("pflow.version", () => UpdateWindow.CurrentVersion);
        Add("pflow.architecture", () => RuntimeInformation.ProcessArchitecture);
        Add("pflow.installedIn", () => InstallFolder(AppContext.BaseDirectory));
        Add("pflow.integrity", () => IntegrityName(LiveTextField.Integrity(0)));
        Add("pflow.elevated", () => new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator));
        Add("pflow.uptimeMinutes", () => Math.Round((DateTime.Now - Process.GetCurrentProcess().StartTime).TotalMinutes, 1));
        Add("windows.edition", () => Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "EditionID", null));
        Add("windows.version", () => Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion", null));
        Add("windows.build", () => Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild", null) + "." + Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR", null));
        Add("windows.architecture", () => RuntimeInformation.OSArchitecture);
        Add("windows.userAccountControl", () => Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", "EnableLUA", null) is int lua ? lua != 0 : null);
        Add("cpu.name", () => (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", null) as string)?.Trim());
        Add("cpu.logicalProcessors", () => Environment.ProcessorCount);
        Add("cpu.cores", () => Cores());
        Add("cpu.avx2", () => RuntimeInformation.ProcessArchitecture == Architecture.X64 || RuntimeInformation.ProcessArchitecture == Architecture.X86 ? Avx2.IsSupported : "not x86");
        Add("cpu.avx2Ready", () => Native.Avx2Ready);
        Add("memory", () => Memory());
        Add("power", () => Power());
        Add("pflow.powerThrottled", () => Throttled(Process.GetCurrentProcess().Handle));
        Add("monitors", () => Monitors());
        Add("touch.points", () => GetSystemMetrics(95));
        Add("keyboard.layouts", () => Layouts());
        Add("engine.worker", () => System.IO.Path.GetFileName(whisper.Executable));
        Add("engine.description", () => whisper.EngineDescription);
        Add("engine.workerRunning", () => whisper.WorkerId != null);
        Add("engine.workerPowerThrottled", () => whisper.WorkerId is int id ? Throttled(Process.GetProcessById(id).Handle) : "no worker");
        Add("engine.workerLoadMs", () => whisper.WorkerLoadMs);
        Add("engine.liveRequests", () => whisper.LiveRequests);
        Add("model.small", () => ModelFile(whisper.ModelPath, SpeechModels.Small.Bytes));
        Add("model.smallSource", () => whisper.ModelSource);
        Add("model.live", () => whisper.LiveModelPath is string live ? ModelFile(live, LiveSpeechModel.Bytes) : "missing");
        Add("model.liveReady", () => whisper.LiveModelReady);
        Add("model.liveRejectedAtLastStart", () => SpeechWorker.LiveModelRejected);
        Add("settings.liveText", () => LiveTextModes.Resolve(store.Preferences.LiveTextMode));
        Add("settings.activationKey", () => activationKey);
        Add("settings.language", () => store.Preferences.Language);
        Add("settings.copyToClipboard", () => store.Preferences.CopyDictationToClipboard);
        return fields;
    }

    /// Facts about the app a take dictates into, read at take start (after the recorder runs).
    internal static DiagField[] Take(InsertionTarget target) =>
        [.. target.Diagnose(), new("power", Safe(Power)), new("pflow.powerThrottled", Safe(() => Throttled(Process.GetCurrentProcess().Handle)))];

    static object? Safe(Func<object?> read) { try { return read(); } catch (Exception error) { return "unreadable (" + error.GetType().Name + ")"; } }

    internal static string IntegrityName(int? level) => level switch {
        null => "unknown", < 0x1000 => "untrusted", < 0x2000 => "low", < 0x3000 => "medium", < 0x4000 => "high", _ => "system"
    };

    /// Where pFlow runs from, as a kind of folder: never the path (it holds the account name).
    internal static string InstallFolder(string folder)
    {
        bool Under(Environment.SpecialFolder special) { string root = Environment.GetFolderPath(special); return root.Length > 0 && folder.StartsWith(root, StringComparison.OrdinalIgnoreCase); }
        return Under(Environment.SpecialFolder.LocalApplicationData) ? "the user's local app data" : Under(Environment.SpecialFolder.ProgramFiles) || Under(Environment.SpecialFolder.ProgramFilesX86) ? "Program Files"
            : Under(Environment.SpecialFolder.UserProfile) ? "elsewhere in the user's folder" : "another folder";
    }

    static string ModelFile(string path, long bytes)
    {
        var file = new FileInfo(path);
        return !file.Exists ? "missing" : file.Length == bytes ? "present, " + file.Length + " bytes (right size)" : "present, " + file.Length + " bytes (WRONG size, expected " + bytes + ")";
    }

    /// Physical cores by efficiency class (0 is the most efficient), with their threads: a Core Ultra 5
    /// 125U reads like "12 cores, 14 threads: class 0 x 2 cores/2 threads, class 1 x 8/8, class 2 x 2/4".
    static string Cores()
    {
        int size = 0;
        GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref size);
        if (size <= 0) return "unknown";
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            if (!GetLogicalProcessorInformationEx(0, buffer, ref size)) return "unknown";
            var classes = new SortedDictionary<int, (int Cores, int Threads)>();
            for (int offset = 0; offset < size;) {
                IntPtr item = buffer + offset;
                int itemSize = Marshal.ReadInt32(item, 4);
                byte efficiency = Marshal.ReadByte(item, 9);
                int threads = 0; short groups = Marshal.ReadInt16(item, 30);
                for (int g = 0; g < groups; g++) threads += System.Numerics.BitOperations.PopCount((ulong)Marshal.ReadIntPtr(item, 32 + g * (IntPtr.Size == 8 ? 16 : 12)).ToInt64());
                var now = classes.GetValueOrDefault(efficiency);
                classes[efficiency] = (now.Cores + 1, now.Threads + threads);
                if (itemSize <= 0) break;
                offset += itemSize;
            }
            int cores = classes.Values.Sum(c => c.Cores), all = classes.Values.Sum(c => c.Threads);
            return cores + " cores, " + all + " threads: " + string.Join(", ", classes.Select(c => "class " + c.Key + " x " + c.Value.Cores + " cores/" + c.Value.Threads + " threads"));
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    static string Memory()
    {
        var status = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        return GlobalMemoryStatusEx(ref status) ? (status.Total / (1024 * 1024)) + " MB total, " + (status.Available / (1024 * 1024)) + " MB free" : "unknown";
    }

    static string Power()
    {
        if (!GetSystemPowerStatus(out var status)) return "unknown";
        string source = status.AcLine switch { 0 => "battery", 1 => "plugged in", _ => "unknown source" };
        string battery = status.Percent == 255 ? "no battery reading" : status.Percent + "% battery";
        return source + ", " + battery + (status.SaverOn != 0 ? ", battery saver ON" : "");
    }

    /// Whether Windows runs a process in efficiency mode (power throttling of execution speed), as far
    /// as the process itself asked: "no" means pFlow left it to Windows' default.
    static string Throttled(IntPtr process)
    {
        var state = new PowerThrottling { Version = 1 };
        if (!GetProcessInformation(process, 4, ref state, Marshal.SizeOf<PowerThrottling>())) return "unknown";
        return (state.ControlMask & 1) == 0 ? "Windows decides" : (state.StateMask & 1) != 0 ? "efficiency mode ON" : "efficiency mode OFF";
    }

    static string Monitors()
    {
        var list = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref Rect bounds, IntPtr _) => {
            string dpi = GetDpiForMonitor(monitor, 0, out uint x, out _) == 0 ? (x * 100 / 96) + "%" : "?";
            list.Add((bounds.Right - bounds.Left) + "x" + (bounds.Bottom - bounds.Top) + " at " + dpi);
            return true;
        }, IntPtr.Zero);
        return list.Count + ": " + string.Join("; ", list);
    }

    static string Layouts()
    {
        int count = GetKeyboardLayoutList(0, null);
        var layouts = new IntPtr[Math.Max(count, 0)];
        if (count > 0) GetKeyboardLayoutList(count, layouts);
        return string.Join(", ", layouts.Select(Layout));
    }

    /// A keyboard layout handle as its language and layout ids, marked when its language types through a
    /// composing input method (Japanese, Chinese, Korean).
    internal static string Layout(IntPtr layout)
    {
        long value = layout.ToInt64();
        string text = (value & 0xFFFF).ToString("x4") + "-" + ((value >> 16) & 0xFFFF).ToString("x4");
        return InputLanguages.Composes((int)(value & 0xFFFF)) ? text + " (composing input method)" : text;
    }

    internal static string ForegroundLayout(IntPtr window) => Layout(GetKeyboardLayout(Native.GetWindowThreadProcessId(window, out _)));

    /// Where reports go: the Downloads folder, unless OneDrive (or another cloud folder) holds it, where a
    /// report would upload by itself; then pFlow's own Reports folder. Returns the folder and how
    /// Settings names it.
    internal static (string Folder, string Label) ReportFolder()
    {
        string? downloads = null;
        try { if (SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out var raw) == 0) { downloads = Marshal.PtrToStringUni(raw); Marshal.FreeCoTaskMem(raw); } }
        catch (Exception error) when (error is EntryPointNotFoundException or COMException) { }
        if (downloads != null && Directory.Exists(downloads) && !Synced(downloads)) return (downloads, "your Downloads folder");
        return (System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "pFlow", "Reports"), "pFlow's Reports folder");
    }

    /// A folder inside OneDrive (personal or work), which uploads what is saved there.
    internal static bool Synced(string folder) =>
        new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" }.Select(name => Environment.GetEnvironmentVariable(name)).Any(root => !string.IsNullOrEmpty(root) && folder.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
        || folder.Split('\\').Any(part => part.StartsWith("OneDrive", StringComparison.OrdinalIgnoreCase));

    /// Writes the report to the reports folder and shows it selected in File Explorer. Returns the file name.
    internal static string Save(string report)
    {
        string folder = ReportFolder().Folder; Directory.CreateDirectory(folder);
        string name = "pFlow diagnostic report " + DateTime.Now.ToString("yyyy-MM-dd HHmmss", System.Globalization.CultureInfo.InvariantCulture) + ".txt";
        string path = System.IO.Path.Combine(folder, name);
        File.WriteAllText(path, report, new System.Text.UTF8Encoding(false));
        try { Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select," + path }, UseShellExecute = false }); } catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        return name;
    }
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);

    [StructLayout(LayoutKind.Sequential)] struct MemoryStatus { public uint Length, Load; public ulong Total, Available, TotalPage, AvailablePage, TotalVirtual, AvailableVirtual, AvailableExtended; }
    [StructLayout(LayoutKind.Sequential)] struct PowerStatus { public byte AcLine, Flag, Percent, SaverOn; public int Seconds, FullSeconds; }
    [StructLayout(LayoutKind.Sequential)] struct PowerThrottling { public uint Version, ControlMask, StateMask; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref Rect bounds, IntPtr data);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref int length);
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out PowerStatus status);
    [DllImport("kernel32.dll")] static extern bool GetProcessInformation(IntPtr process, int kind, ref PowerThrottling information, int size);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc callback, IntPtr data);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int kind, out uint x, out uint y);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count, IntPtr[]? layouts);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
}

/// Settings → Troubleshooting → "Save a diagnostic report": the recorder's report with this PC's facts,
/// saved in Downloads (or pFlow's Reports folder when Downloads is in OneDrive) and shown in File
/// Explorer. Returns the line shown under the button.
internal static class DiagnosticReport
{
    internal const string ButtonLabel = "Save a diagnostic report";
    /// The one line above the button: what it is for and where the file goes.
    internal static string Explanation => "Helps fix problems. Contains no dictated words. Saved in " + DiagnosticEnvironment.ReportFolder().Label + ".";
    internal static string Save(Whisper whisper, StateStore store, string activationKey)
    {
        try {
            string report = Diagnostics.Recorder.Report(DiagnosticEnvironment.Collect(whisper, store, activationKey));
            string name = DiagnosticEnvironment.Save(report);
            return "Saved in " + DiagnosticEnvironment.ReportFolder().Label + ": " + name;
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) {
            return "Could not save the report: " + PrivateLog.Scrub(error.Message);
        }
    }
}
