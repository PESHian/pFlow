using System.Runtime.InteropServices;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PFlow.Windows;
using PFlow.Core;
using System.Text;

internal static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowStation(string name, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder buffer, int length, out int needed);
    [DllImport("user32.dll")] static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo {
        public int Size; public string? Reserved, Desktop, Title;
        public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedSize; public IntPtr ReservedData, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public uint Id, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); passed++; }
    static string ObjectName(IntPtr handle)
    {
        var name = new StringBuilder(256);
        if (!GetUserObjectInformation(handle, 2, name, 512, out _)) throw new Exception("Could not verify private test desktop.");
        return name.ToString();
    }
    static int LaunchPrivate()
    {
        string name = "pFlowFixture-" + Guid.NewGuid().ToString("N");
        string report = Path.Combine(Path.GetTempPath(), name + ".txt");
        IntPtr previous = GetProcessWindowStation(), station = IntPtr.Zero, desktop = IntPtr.Zero;
        try {
            station = CreateWindowStation(name, 0, 0x37F, IntPtr.Zero);
            if (station == IntPtr.Zero || !SetProcessWindowStation(station)) throw new Exception("Could not create a private clipboard station.");
            desktop = CreateDesktop("fixture", IntPtr.Zero, IntPtr.Zero, 0, 0x1FF, IntPtr.Zero);
            if (desktop == IntPtr.Zero) throw new Exception("Could not create private desktop: " + Marshal.GetLastWin32Error());
            string executable = Environment.ProcessPath!;
            var command = new StringBuilder("\"" + executable + "\" --worker \"" + report + "\" " + name);
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = name + "\\fixture" };
            if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref startup, out var process)) throw new Exception("Private test launch failed: " + Marshal.GetLastWin32Error());
            try {
                if (WaitForSingleObject(process.Process, 120000) != 0) throw new Exception("Private clipboard fixture timed out.");
                GetExitCodeProcess(process.Process, out uint code);
                if (File.Exists(report)) Console.Write(File.ReadAllText(report));
                return (int)code;
            } finally { CloseHandle(process.Process); CloseHandle(process.Thread); }
        } finally {
            SetProcessWindowStation(previous); if (desktop != IntPtr.Zero) CloseDesktop(desktop); if (station != IntPtr.Zero) CloseWindowStation(station);
            if (File.Exists(report)) File.Delete(report);
        }
    }
    [STAThread] static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--architecture-speech") return ArchitectureSpeech(args[1], args[2]).GetAwaiter().GetResult();
        if (args.Length > 0 && args[0] == "--model") return ModelChecks(args[1], args.Contains("--cleanup-only"));
        if (args.Length == 0) { try { return LaunchPrivate(); } catch (Exception error) { Console.Error.WriteLine(error); return 1; } }
        using var reportWriter = new StreamWriter(args[1]) { AutoFlush = true }; Console.SetOut(reportWriter); Console.SetError(reportWriter);
        try {
            Check("isolated window station", ObjectName(GetProcessWindowStation()) == args[2]);
            Check("isolated desktop", ObjectName(GetThreadDesktop(GetCurrentThreadId())) == "fixture");
            Check("INPUT size matches Windows ABI", Marshal.SizeOf<Native.Input>() == (IntPtr.Size == 8 ? 40 : 28));
            Check("INPUT union alignment matches Windows ABI", Marshal.OffsetOf<Native.Input>(nameof(Native.Input.Data)).ToInt32() == (IntPtr.Size == 8 ? 8 : 4));
            Check("keyboard structure matches Windows ABI", Marshal.SizeOf<Native.KeyboardInput>() == (IntPtr.Size == 8 ? 24 : 16));
            Check("keyboard hook structure matches Windows ABI", Marshal.SizeOf<Native.HookKey>() == (IntPtr.Size == 8 ? 24 : 20));
            Check("wave header matches Windows ABI", Marshal.SizeOf(typeof(WaveRecorder).GetNestedType("Header", System.Reflection.BindingFlags.NonPublic)!) == (IntPtr.Size == 8 ? 48 : 32));
            string architectureFixture = Path.Combine(Path.GetTempPath(), "pflow-architecture-" + Guid.NewGuid().ToString("N"));
            var capsule = new Capsule(new StateStore(architectureFixture));
            try {
                var handle = new WindowInteropHelper(capsule).EnsureHandle();
                var style = Native.GetWindowLongPtr(handle, -20);
                Check("capsule native window style works on this architecture", (style.ToInt64() & 0x08000080) == 0x08000080);
                Native.SetWindowLongPtr(handle, -20, style);
                Check("native window style round-trip", Native.GetWindowLongPtr(handle, -20) == style);
            } finally { capsule.Close(); if (Directory.Exists(architectureFixture)) Directory.Delete(architectureFixture, true); }
            Check("local AI capability matches process width", LocalTextModel.IsSupported == Environment.Is64BitProcess);
            if (!Environment.Is64BitProcess) {
                var unsupported = new LocalTextModel(Path.GetTempPath());
                bool refused = false;
                try { unsupported.Download(new Progress<double>(), CancellationToken.None).GetAwaiter().GetResult(); }
                catch (NotSupportedException error) { refused = error.Message == LocalTextModel.UnsupportedReason; }
                Check("32-bit AI download refused before network or disk use", refused && !unsupported.FilesPresent);
            }
            using var window = new HwndSource(new HwndSourceParameters("pFlow private clipboard fixture") { Width = 10, Height = 10 });
            Clipboard.SetText("Fictional private clipboard 123 👮");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put("Narration 李 123.");
                Check("sequence stable after close", Native.GetClipboardSequenceNumber() == lease.InstalledSequence);
                Check("temporary dictation text", Clipboard.GetText() == "Narration 李 123.");
                Check("sequence stable after text read", Native.GetClipboardSequenceNumber() == lease.InstalledSequence);
                Check("clipboard restored", lease.Restore());
                var actualText = Clipboard.GetText();
                if (actualText != "Fictional private clipboard 123 👮") Console.WriteLine("Private fixture mismatch: " + System.Text.Json.JsonSerializer.Serialize(actualText));
                Check("Unicode clipboard restored exactly", actualText == "Fictional private clipboard 123 👮");
            }
            Clipboard.SetText("Old fictional copy");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put("Dictation"); Clipboard.SetText("Newer fictional copy");
                Check("newer clipboard restoration returns", lease.Restore()); Check("newer clipboard preserved", Clipboard.GetText() == "Newer fictional copy");
            }
            Clipboard.SetText("Original fictional copy");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put("Dictation"); Clipboard.SetText("Private newer copy after final focus check");
                bool refused = false; try { lease.DispatchPaste(); } catch (InvalidOperationException) { refused = true; }
                Check("newer copy before paste never dispatched", refused && Clipboard.GetText() == "Private newer copy after final focus check");
                Check("newer copy after put not overwritten", lease.Restore());
            }
            Clipboard.SetText("First fictional copy");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put("Identical fictional text"); Clipboard.SetText("Identical fictional text");
                Check("identical newer copy is not owned", Native.GetClipboardSequenceNumber() != lease.InstalledSequence);
                Check("identical newer copy preserved", lease.Restore() && Clipboard.GetText() == "Identical fictional text");
            }
            Clipboard.SetText("First fictional copy");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                Clipboard.SetText("Changed before insertion"); bool refused = false;
                try { lease.Put("Must not overwrite"); } catch (InvalidOperationException) { refused = true; }
                Check("snapshot race refused", refused && Clipboard.GetText() == "Changed before insertion");
            }
            var image = BitmapSource.Create(2, 2, 96, 96, PixelFormats.Bgra32, null, new byte[] { 1, 2, 200, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, 8);
            Clipboard.SetImage(image);
            try {
                using var opaque = new ClipboardLease(window.Handle, true);
                Console.WriteLine("WPF bitmap snapshot is supported on this runtime.");
            } catch (InvalidOperationException error) when ((string?)error.Data["FormatName"] == "System.Drawing.Bitmap") {
                Console.WriteLine("NOT SUPPORTED: WPF opaque System.Drawing.Bitmap representation. Plain insertion uses Unicode without changing this clipboard.");
                Check("unsupported WPF clipboard remains an image", Clipboard.ContainsImage());
            }
            var dib = new byte[56];
            using (var writer = new BinaryWriter(new MemoryStream(dib))) {
                writer.Write(40); writer.Write(2); writer.Write(-2); writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(0); writer.Write(16);
            }
            new byte[] { 1, 2, 200, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }.CopyTo(dib, 40);
            var dibHandle = Native.GlobalAlloc(2, (UIntPtr)dib.Length); var dibPointer = Native.GlobalLock(dibHandle);
            Marshal.Copy(dib, 0, dibPointer, dib.Length); Native.GlobalUnlock(dibHandle);
            if (!Native.OpenClipboard(window.Handle)) throw new Exception("Private image fixture clipboard was busy.");
            try { Native.EmptyClipboard(); if (Native.SetClipboardData(8, dibHandle) == IntPtr.Zero) throw new Exception("Could not install native screenshot fixture."); }
            finally { Native.CloseClipboard(); }
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put("A fictional narration over a native screenshot."); Check("native screenshot restored", lease.Restore());
                if (!Native.OpenClipboard(window.Handle)) throw new Exception("Private image fixture clipboard was busy.");
                try {
                    var data = Native.GetClipboardData(8); var pointer = Native.GlobalLock(data); var bytes = new byte[56];
                    Marshal.Copy(pointer, bytes, 0, bytes.Length); Native.GlobalUnlock(data);
                    Check("native screenshot dimensions and every pixel survive", bytes.SequenceEqual(dib));
                } finally { Native.CloseClipboard(); }
            }
            var template = new DictationTemplate { Name = "Fixture", Title = "Title", BoldHeadings = true, Sections = [new() { Title = "Narrative", IncludeFullDictation = true }] };
            var rendered = RichText.Render("Narrative stays plain. 李 👮", template);
            Clipboard.SetText("Original fictional text");
            using (var lease = new ClipboardLease(window.Handle, true)) {
                lease.Put(rendered.Text, rendered.Rtf);
                Check("rich clipboard plain text unchanged", Clipboard.GetText() == rendered.Text);
                Check("RTF supplied", Clipboard.ContainsData(DataFormats.Rtf));
                var document = new System.Windows.Documents.FlowDocument();
                var range = new System.Windows.Documents.TextRange(document.ContentStart, document.ContentEnd);
                using var stream = new MemoryStream(System.Text.Encoding.ASCII.GetBytes(rendered.Rtf!)); range.Load(stream, DataFormats.Rtf);
                Check("RTF preserves Unicode", range.Text.TrimEnd('\r', '\n') == rendered.Text.Replace("\n", "\r\n"));
                Check("rich clipboard restored", lease.Restore());
            }
            Console.WriteLine($"{passed} native private-clipboard checks passed."); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); foreach (System.Collections.DictionaryEntry data in error.Data) Console.Error.WriteLine($"Fixture detail: {data.Key}={data.Value}"); return 1; }
    }
    static async Task<int> ArchitectureSpeech(string assets, string audio)
    {
        string directory = Path.Combine(Path.GetTempPath(), "pflow-speech-architecture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try {
            await using var whisper = new Whisper(directory, assets);
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            await whisper.Prewarm();
            int? worker = whisper.WorkerId;
            string first = await whisper.Transcribe(audio, "en", [], deadline.Token);
            string words = string.Join(" ", first.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            Check("native CPU transcription retains public JFK words", words.Contains("ask not what your country can do for you") && words.Contains("ask what you can do for your country"));
            string second = await whisper.Transcribe(audio, "en", [], deadline.Token);
            Check("resident worker works repeatedly on this architecture", second == first && worker != null && whisper.WorkerId == worker && whisper.LastMetrics.Reused);
            bool locked = false;
            try { using var change = new FileStream(whisper.ModelPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite); }
            catch (IOException) { locked = true; }
            Check("model stays protected while resident", locked);
            Console.WriteLine($"{passed} architecture speech checks passed ({RuntimeInformation.ProcessArchitecture}).");
            return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { Directory.Delete(directory, true); }
    }
    static int ModelChecks(string assets, bool cleanupOnly)
    {
        string directory = Path.Combine(Path.GetTempPath(), "pFlow-model-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        try {
            var model = new LocalTextModel(directory, assets);
            string source = "The server server stopped. Officer Morgan Lee did not restart it.";
            var watch = System.Diagnostics.Stopwatch.StartNew();
            string cleaned = model.Cleanup(source, directory, CancellationToken.None).GetAwaiter().GetResult();
            Console.WriteLine("Model fixture diagnostic: " + (model.LastIssue ?? "no error; response accepted"));
            Check("real local model makes a cleanup edit", System.Text.RegularExpressions.Regex.Matches(cleaned, "server", System.Text.RegularExpressions.RegexOptions.IgnoreCase).Count == 1);
            Check("local cleanup preserves name and negation", cleaned.Contains("Morgan Lee") && cleaned.Contains("did not"));
            string numeric = "The server server stopped at 14:30. Morgan said \"Alex hit Pesh\".";
            Check("risky numeric and quoted block stays exact", model.Cleanup(numeric, directory, CancellationToken.None).GetAwaiter().GetResult() == numeric);
            Console.WriteLine($"Cleanup seconds: {watch.Elapsed.TotalSeconds:F1}");
            if (cleanupOnly) { Console.WriteLine($"{passed} actual cleanup checks passed."); return 0; }
            var template = DictationTemplate.LegacyExamples()[0]; template.BoldHeadings = true;
            string narrative = "I am Officer Morgan Lee, badge 123, with the fictional training agency. On October 12 at 14:30, I arrived at 12 Maple Street. I spoke with Alex Rivera. No staff were injured. I photographed a blue bicycle as evidence item 101. No property was collected.";
            var result = model.Report(narrative, template, directory, CancellationToken.None).GetAwaiter().GetResult();
            Check("real local report generated", result.HasValue);
            Check("full narrative keeps every fact", result!.Value.Text.Contains("Narrative\n" + narrative));
            Check("local report includes bold headings", result.Value.Rtf!.Contains(@"\b Narrative\b0"));
            string identity = result.Value.Text.Split("Narrated by\n")[1].Split("\n\n")[0];
            Check("report identity includes stated name and badge", identity.Contains("Morgan Lee") && identity.Contains("123"));
            Console.WriteLine($"{passed} actual local model checks passed."); return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { Directory.Delete(directory, true); }
    }
}
