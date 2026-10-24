using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using PFlow.Core;
using PFlow.Windows;
using Forms = System.Windows.Forms;

// W028: apps whose fields UI Automation cannot read.
// --writer   LibreOffice Writer (its own fictional profile and file): Off and Type takes go into the document once
//            each (read back from the file Writer saves, not through pFlow's own reader), a two-line insert, focus
//            moved away before the insert (nothing pasted anywhere), the password prompt of a locked fictional
//            file (the take is refused; the real fictional password then opens the file, so nothing went into the
//            box), the clipboard restored after every take; Notepad++ (Scintilla) and a RichEdit box as more apps.
internal static partial class Program
{
    static bool writerOnly, terminalsOnly, historyCopyOnly;
    const string Soffice = @"C:\Program Files\LibreOffice\program\soffice.exe";
    const string LockedPassword = "fictional-secret";

    sealed record Fixture(Process Process, IntPtr Window, string Name, string File);

    /// A fresh LibreOffice profile with no tips, no "keep format?" question and no what's-new bar.
    static string WriterProfile()
    {
        string profile = Path.Combine(root, "lo-profile-fictional-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path.Combine(profile, "user"));
        string Item(string path, string name, string value) => $"<item oor:path=\"{path}\"><prop oor:name=\"{name}\" oor:op=\"fuse\"><value>{value}</value></prop></item>";
        File.WriteAllText(Path.Combine(profile, "user", "registrymodifications.xcu"), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<oor:items xmlns:oor=\"http://openoffice.org/2001/registry\" xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + Item("/org.openoffice.Office.Common/Misc", "ShowTipOfTheDay", "false") + Item("/org.openoffice.Office.Common/Misc", "FirstRun", "false")
            + Item("/org.openoffice.Office.Common/Save/Document", "WarnAlienFormat", "false") + Item("/org.openoffice.Setup/Product", "ooSetupLastVersion", "26.8")
            + "</oor:items>");
        return profile;
    }

    static async Task<Fixture> OpenWriter(string profile, string file, string titlePart)
    {
        var start = new ProcessStartInfo(Soffice) { UseShellExecute = false };
        foreach (string arg in new[] { "-env:UserInstallation=" + new Uri(profile).AbsoluteUri, "--norestore", "--nologo", "--writer", file }) start.ArgumentList.Add(arg);
        var process = Process.Start(start)!;
        IntPtr window = IntPtr.Zero;
        for (int i = 0; i < 300 && window == IntPtr.Zero; i++) {
            await Task.Delay(200);
            foreach (var p in Process.GetProcessesByName("soffice.bin")) { try { if (p.MainWindowTitle.Contains(titlePart)) window = p.MainWindowHandle; } catch { } }
        }
        Check("Writer: the window for " + titlePart + " appeared", window != IntPtr.Zero);
        await Task.Delay(2500);
        return new(process, window, titlePart, file);
    }

    static async Task Front(IntPtr window, string what)
    {
        for (int i = 0; i < 6 && Native.GetForegroundWindow() != window; i++) { Front(window); await Task.Delay(400); }
        Check(what + " is in front", Native.GetForegroundWindow() == window);
    }

    static void Keys(params ushort[] chord)
    {
        var inputs = chord.Select(k => Native.Key(k)).Concat(chord.Reverse().Select(k => Native.Key(k, true))).ToArray();
        Native.Send(inputs);
    }

    /// Ctrl+S, then the file as the app wrote it (the read-back that does not use pFlow's own reader).
    static async Task<string> SavedText(IntPtr window, string file, string what)
    {
        await Front(window, what);
        var before = File.GetLastWriteTimeUtc(file);
        Keys(0x11, 0x53);
        for (int i = 0; i < 50 && File.GetLastWriteTimeUtc(file) == before; i++) await Task.Delay(100);
        await Task.Delay(300);
        Check(what + ": the app saved the file", File.GetLastWriteTimeUtc(file) != before);
        for (int i = 0; ; i++) {
            // The app keeps its file open: read it shared.
            try { using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); using var reader = new StreamReader(stream, Encoding.UTF8); return reader.ReadToEnd().TrimStart('\uFEFF'); }
            catch (IOException) when (i < 20) { await Task.Delay(100); }
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
    /// Which program holds the clipboard open (a busy clipboard is worth a line in the log).
    static string ClipboardHolder()
    {
        IntPtr holder = GetOpenClipboardWindow();
        if (holder == IntPtr.Zero) return "nobody";
        Native.GetWindowThreadProcessId(holder, out uint process);
        try { using var p = Process.GetProcessById((int)process); return p.ProcessName; } catch (ArgumentException) { return "a closed program"; }
    }
    static string ClipboardText()
    {
        for (int i = 0; ; i++) {
            try { return Forms.Clipboard.ContainsText() ? Forms.Clipboard.GetText() : ""; }
            catch (System.Runtime.InteropServices.ExternalException) when (i < 50) { if (i % 10 == 0) Console.WriteLine("WRITER clipboard busy (read), held by " + ClipboardHolder()); Thread.Sleep(100); }
        }
    }
    static void SetClipboard(string text)
    {
        for (int i = 0; ; i++) {
            try { Forms.Clipboard.SetDataObject(text, true, 1, 50); return; }
            // The VM's SPICE agent (vdagent) can hold the clipboard for seconds while it syncs a copy to the host.
            catch (System.Runtime.InteropServices.ExternalException) when (i < 300) { if (i % 10 == 0) Console.WriteLine("WRITER clipboard busy (write), held by " + ClipboardHolder()); Thread.Sleep(100); }
        }
    }

    static void Kill(Process? process)
    {
        try { if (process is { HasExited: false }) { process.Kill(true); process.WaitForExit(5000); } } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? className, string? title);

    /// Consoles, Windows Terminal and PowerShell ISE: what UI Automation shows there (what 0.1.27's paths would
    /// have done), and that pFlow refuses to type or paste (NoTypePlaces) with the clipboard untouched.
    static async Task Terminals(IntPtr owner)
    {
        async Task Try(string what, ProcessStartInfo start, Func<Process, IntPtr> window, Func<Task>? focus = null, bool required = true)
        {
            Process? process = null; IntPtr handle = IntPtr.Zero;
            try {
                process = Process.Start(start);
                for (int i = 0; i < 60 && handle == IntPtr.Zero; i++) { await Task.Delay(250); handle = window(process!); }
                if (handle == IntPtr.Zero) { Console.WriteLine($"WRITER terminal {what}: NOT RUN (no window)"); return; }
                await Task.Delay(1500); await Front(handle, what); if (focus != null) await focus(); await Task.Delay(500);
                var e = AutomationElement.FocusedElement; string facts;
                try {
                    var c = e.Current; bool text = e.TryGetCurrentPattern(TextPattern.Pattern, out var tp); object? ro = text ? ((TextPattern)tp).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute) : null;
                    facts = $"window={LiveTextField.ClassName(handle)} element={c.ControlType.ProgrammaticName.Replace("ControlType.", "")}/{c.ClassName}/{c.FrameworkId} id=[{c.AutomationId}] focusable={c.IsKeyboardFocusable} textPattern={text} readOnly={ro} value={e.TryGetCurrentPattern(ValuePattern.Pattern, out _)}";
                } catch (Exception error) { facts = "facts unreadable: " + error.GetType().Name; }
                uint sequence = Native.GetClipboardSequenceNumber();
                string status;
                try { var t = InsertionTarget.Capture(); status = await t.Insert("Fictional words that must not run.\necho fictional", owner, false, CancellationToken.None) + " (kind " + t.Kind + ")"; }
                catch (InvalidOperationException error) { status = "refused at the start: " + error.Message; }
                Console.WriteLine($"WRITER terminal {what}: {facts} -> status=[{status}] clipboard touched={Native.GetClipboardSequenceNumber() != sequence}");
                if (required) Check($"{what}: pFlow refuses to type or paste there, clipboard untouched", status.StartsWith(NoTypePlaces.Terminal, StringComparison.Ordinal) && Native.GetClipboardSequenceNumber() == sequence);
            } finally {
                // Only what this check opened: its window is asked to close, and the program it started ends.
                if (handle != IntPtr.Zero) { PostMessage(handle, 0x0010, IntPtr.Zero, IntPtr.Zero); await Task.Delay(1500); }
                Kill(process);
            }
        }
        string title = "pflow-fictional-console-" + Guid.NewGuid().ToString("N")[..6];
        var console = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "conhost.exe")) { UseShellExecute = false };
        foreach (string a in new[] { "cmd.exe", "/k", "title " + title }) console.ArgumentList.Add(a);
        IntPtr ByTitle(string part) { IntPtr found = IntPtr.Zero; foreach (var p in Process.GetProcesses()) { try { if (p.MainWindowTitle.Contains(part)) found = p.MainWindowHandle; } catch { } finally { p.Dispose(); } } return found; }
        await Try("console (conhost)", console, _ => ByTitle(title));
        string wtTitle = "pflow-fictional-wt-" + Guid.NewGuid().ToString("N")[..6];
        var wt = new ProcessStartInfo("wt.exe") { UseShellExecute = true };
        foreach (string a in new[] { "-w", "new", "--title", wtTitle, "--suppressApplicationTitle", "cmd.exe" }) wt.ArgumentList.Add(a);
        await Try("Windows Terminal", wt, _ => ByTitle(wtTitle));
        string ise = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell_ise.exe");
        if (File.Exists(ise)) {
            // ISE's console pane: by UI Automation, where it can be told from the script pane (printed below).
            await Try("PowerShell ISE", new ProcessStartInfo(ise, "-NoProfile") { UseShellExecute = false }, p => { p.Refresh(); return p.MainWindowHandle; },
                async () => { Keys(0x11, 0x44); await Task.Delay(500); }, required: false); // Ctrl+D: Go to Console pane
        }
    }

    static async Task Writer()
    {
        var rig = Rig("writer");
        string profile = WriterProfile();
        var opened = new List<Process>();
        string? hostDirectory = null;
        const string marker = "pflow fictional clipboard marker";
        int exact = 0, takes = 0;
        try {
            await rig.Whisper.Prewarm();
            Console.WriteLine($"WRITER engine '{rig.Whisper.EngineDescription}'");
            // Clipboard history (Win+V): a copy of the harness's own goes in (positive control); pFlow's words must not.
            string control = "pflow fictional history control " + Guid.NewGuid().ToString("N")[..8];
            SetClipboard(control); await Task.Delay(1500);
            Console.WriteLine("WRITER history control: " + control);
            string name = "pflow-fictional-writer-" + Guid.NewGuid().ToString("N")[..8];
            string file = Path.Combine(rig.Directory, name + ".txt");
            const string prefix = "Fictional prefix.";
            File.WriteAllText(file, prefix);
            var writer = await OpenWriter(profile, file, name); opened.Add(writer.Process);
            await Front(writer.Window, "Writer"); Keys(0x11, 0x23); await Task.Delay(500);
            string expected = prefix;
            foreach (var (audio, mode) in new[] { ("short-1.wav", LiveTextModes.Off), ("medium-1.wav", LiveTextModes.Off), ("short-2.wav", LiveTextModes.Off),
                                                  ("short-3.wav", LiveTextModes.TypeInApp), ("medium-2.wav", LiveTextModes.TypeInApp), ("short-4.wav", LiveTextModes.TypeInApp) }) {
                string take = "writer-" + mode + "-" + Path.GetFileNameWithoutExtension(audio);
                await Front(writer.Window, take);
                SetClipboard(marker);
                var r = await TypeTake(take, audio, rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "soffice.bin", mode);
                takes++;
                if (takes == 1) foreach (string line in r.Section.Split('\n').Where(l => Regex.IsMatch(l, "capture\\.detail|typing\\.field|insert|result"))) Console.WriteLine("WRITER diag> " + line.TrimEnd());
                string saved = await SavedText(writer.Window, file, take);
                expected = expected + " " + r.Final;
                bool same = Flat(saved) == Flat(expected);
                int copies = r.Final.Length >= 12 ? Occurrences(Flat(saved), Flat(r.Final)) : -1;
                string clip = ClipboardText();
                Console.WriteLine($"WRITER {take}: status=[{r.Status}] live writes={r.Writes} field=[{r.FieldWhy}] file exact={same} copies={copies} clipboard restored={clip == marker} final={r.Report.FinalMs:F0}ms");
                Console.WriteLine("WRITER final text: " + r.Final.Trim());
                if (same && copies == 1 && r.Status == "Inserted") exact++;
                Check($"{take}: the finished text is in the document exactly once, checked ({r.Status})", r.Status == "Inserted" && same && copies == 1);
                Check($"{take}: no live words typed into Writer", r.Writes == 0 && !r.Typed);
                Check($"{take}: the clipboard holds what it held before", clip == marker);
            }
            Console.WriteLine($"WRITER takes exact once: {exact}/{takes}");

            // Two lines: Writer makes a second paragraph; the check reads across both.
            await Front(writer.Window, "Writer two lines");
            var two = InsertionTarget.Capture();
            string lines = await two.Insert("Fictional line one.\nFictional line two.", rig.Owner.Handle, false, CancellationToken.None);
            string afterTwo = await SavedText(writer.Window, file, "two lines");
            bool twoExact = Normalize(afterTwo).TrimEnd('\n') == Normalize(expected + " Fictional line one.\nFictional line two.");
            Console.WriteLine($"WRITER two lines: status=[{lines}] file exact={twoExact}");
            Check("two lines go in as two paragraphs, checked", lines == "Inserted" && twoExact);
            expected += " Fictional line one.\nFictional line two.";

            // Focus moves to another window between the start of the take and the insert: nothing anywhere.
            hostDirectory = Path.Combine(root, "pflow-fictional-writer-host-" + Guid.NewGuid().ToString("N")[..8]);
            await StartHost(hostDirectory);
            var host = await WindowWith(Path.GetFileName(hostDirectory) + " host");
            var rich = Named(host, "Fictional rich");
            await Front(writer.Window, "Writer focus");
            var away = InsertionTarget.Capture();
            await Place(host, rich);
            string richBefore = Read(rich);
            uint sequence = Native.GetClipboardSequenceNumber();
            string moved;
            try { moved = await away.Insert("Fictional words that must not land.", rig.Owner.Handle, false, CancellationToken.None); }
            catch (InvalidOperationException error) { moved = error.Message; }
            await Task.Delay(800);
            string afterMoved = await SavedText(writer.Window, file, "focus moved");
            Console.WriteLine($"WRITER focus moved: status=[{moved}] clipboard touched={Native.GetClipboardSequenceNumber() != sequence}");
            Check("focus moved away: refused, Writer and the other window unchanged, clipboard untouched",
                moved.StartsWith("Focus changed", StringComparison.Ordinal) && Normalize(afterMoved).TrimEnd('\n') == Normalize(expected) && Read(rich) == richBefore && Native.GetClipboardSequenceNumber() == sequence);

            // RichEdit (WordPad's control): an Off take into the host's rich box.
            await Place(host, rich); PersonSelects(rich, Read(rich).Length, Read(rich).Length);
            string richStart = Read(rich);
            var rr = await TypeTake("richedit-off", "short-5.wav", rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, null, LiveTextModes.Off);
            string richAfter = Read(rich);
            bool richExact = Normalize(richAfter) == Normalize(richStart + " " + rr.Final) || Normalize(richAfter) == Normalize(richStart + rr.Final);
            Console.WriteLine($"WRITER richedit: status=[{rr.Status}] exact={richExact}");
            Check("RichEdit: the finished text goes in once, checked", rr.Status == "Inserted" && richExact);

            // Notepad++ (Scintilla: no UI Automation text), Off and Type.
            string npp = Path.GetFullPath(Path.Combine(root, "..", "npp", "app", "notepad++.exe"));
            if (!File.Exists(npp)) Console.WriteLine("WRITER notepad++: NOT RUN (not installed at " + Path.GetFileName(Path.GetDirectoryName(npp)) + ")");
            else {
                string nppFile = Path.Combine(rig.Directory, "pflow-fictional-npp-" + Guid.NewGuid().ToString("N")[..8] + ".txt");
                File.WriteAllText(nppFile, prefix);
                var start = new ProcessStartInfo(npp) { UseShellExecute = false };
                foreach (string arg in new[] { "-multiInst", "-nosession", "-notabbar", nppFile }) start.ArgumentList.Add(arg);
                var nppProcess = Process.Start(start)!; opened.Add(nppProcess);
                IntPtr nppWindow = IntPtr.Zero;
                for (int i = 0; i < 100 && nppWindow == IntPtr.Zero; i++) { await Task.Delay(200); nppProcess.Refresh(); if (nppProcess.MainWindowTitle.Contains(Path.GetFileName(nppFile))) nppWindow = nppProcess.MainWindowHandle; }
                Check("Notepad++ window appeared", nppWindow != IntPtr.Zero);
                await Task.Delay(1000); await Front(nppWindow, "Notepad++"); Keys(0x11, 0x23); await Task.Delay(300);
                string nppExpected = prefix;
                foreach (var (audio, mode) in new[] { ("short-1.wav", LiveTextModes.Off), ("short-2.wav", LiveTextModes.TypeInApp) }) {
                    string take = "npp-" + mode;
                    await Front(nppWindow, take); SetClipboard(marker);
                    var r = await TypeTake(take, audio, rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "notepad++", mode);
                    string saved = await SavedText(nppWindow, nppFile, take);
                    nppExpected += " " + r.Final;
                    bool same = Flat(saved) == Flat(nppExpected); string clip = ClipboardText();
                    Console.WriteLine($"WRITER {take}: status=[{r.Status}] file exact={same} clipboard restored={clip == marker}");
                    Console.WriteLine("WRITER final text: " + r.Final.Trim());
                    Check($"{take}: the finished text is in the file exactly once ({r.Status})", (r.Status == "Inserted" || r.Status.StartsWith("Pasted into the app", StringComparison.Ordinal)) && same);
                    Check($"{take}: the clipboard holds what it held before", clip == marker);
                }
                // Two carets (Scintilla's multiple selection): a paste would land at each one and could not be checked,
                // so the take is refused at the start and nothing goes in.
                {
                    IntPtr sci = FindWindowEx(nppWindow, IntPtr.Zero, "Scintilla", null);
                    await Front(nppWindow, "npp two carets");
                    int length = (int)SendMessage(sci, 2006, IntPtr.Zero, IntPtr.Zero); // SCI_GETLENGTH
                    SendMessage(sci, 2563, (IntPtr)1, IntPtr.Zero);                     // SCI_SETMULTIPLESELECTION
                    SendMessage(sci, 2572, (IntPtr)length, (IntPtr)length);             // SCI_SETSELECTION caret, anchor
                    SendMessage(sci, 2573, (IntPtr)9, (IntPtr)9);                       // SCI_ADDSELECTION
                    int carets = (int)SendMessage(sci, 2570, IntPtr.Zero, IntPtr.Zero); // SCI_GETSELECTIONS
                    SetClipboard(marker);
                    // The document was just saved: unmodified (SCI_GETMODIFY 0) and its length are the read-back.
                    bool cleanBefore = SendMessage(sci, 2159, IntPtr.Zero, IntPtr.Zero) == IntPtr.Zero;
                    var r = await TypeTake("npp-two-carets", "short-3.wav", rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "notepad++", LiveTextModes.Off);
                    await Task.Delay(500);
                    bool unchanged = cleanBefore && SendMessage(sci, 2159, IntPtr.Zero, IntPtr.Zero) == IntPtr.Zero && (int)SendMessage(sci, 2006, IntPtr.Zero, IntPtr.Zero) == length;
                    string clip = ClipboardText();
                    Console.WriteLine($"WRITER npp two carets: carets={carets} status=[{r.Status}] document unchanged={unchanged} (clean before={cleanBefore}, length {length} -> {(int)SendMessage(sci, 2006, IntPtr.Zero, IntPtr.Zero)}) clipboard restored={clip == marker}");
                    Check($"two carets in Notepad++: refused, nothing pasted, the Copy card offers the words ({r.Status})", carets == 2 && unchanged && clip == marker
                        && !r.Status.StartsWith("Inserted", StringComparison.Ordinal) && InsertionPrompt.Needed(r.Status, false));
                }
                Kill(nppProcess);
            }
            await Terminals(rig.Owner.Handle);
            QuitHost(hostDirectory);

            // A locked fictional file: Writer asks for its password. The take is refused; the right password then opens it.
            string locked = Path.Combine(root, "pflow-fictional-locked.odt");
            if (!File.Exists(locked)) Console.WriteLine("WRITER password: NOT RUN (no locked fixture)");
            else {
                string copy = Path.Combine(rig.Directory, "pflow-fictional-locked-" + Guid.NewGuid().ToString("N")[..8] + ".odt"); File.Copy(locked, copy);
                // The running instance opens it (a fresh profile's first start shows no prompt).
                var start = new ProcessStartInfo(Soffice) { UseShellExecute = false };
                foreach (string arg in new[] { "-env:UserInstallation=" + new Uri(profile).AbsoluteUri, "--norestore", "--nologo", copy }) start.ArgumentList.Add(arg);
                opened.Add(Process.Start(start)!);
                AutomationElement? dialog = null;
                // The prompt is a SALSUBFRAME owned by Writer's frame: UI Automation lists it under that frame.
                for (int i = 0; i < 60 && dialog == null; i++) {
                    await Task.Delay(500);
                    dialog = AutomationElement.RootElement.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ClassNameProperty, "SALSUBFRAME")).Cast<AutomationElement>()
                        .FirstOrDefault(w => w.Current.Name.StartsWith("Password Protection", StringComparison.Ordinal) && w.Current.Name.Contains(Path.GetFileName(copy)));
                }
                if (dialog == null) foreach (var p in Process.GetProcessesByName("soffice.bin")) { try { Console.WriteLine("WRITER password: no prompt; LibreOffice window: " + (p.MainWindowTitle.Contains("pflow-fictional") ? "fixture" : p.MainWindowTitle)); } catch { } }
                Check("Writer asks for the fictional file's password", dialog != null);
                IntPtr dialogWindow = (IntPtr)dialog!.Current.NativeWindowHandle;
                await Task.Delay(1500); await Front(dialogWindow, "password prompt"); await Task.Delay(800);
                uint sequence2 = Native.GetClipboardSequenceNumber();
                // Twice: right away (Writer may not have built the prompt's accessibility yet) and once it has.
                var outcomes = new List<string>();
                foreach (int wait in new[] { 0, 2000 }) {
                    // The second time as a person would leave it: Tab away and back, so the box has focus for sure.
                    if (wait > 0) { await Front(dialogWindow, "password prompt"); Keys(0x09); await Task.Delay(300); Keys(0x10, 0x09); }
                    await Task.Delay(wait);
                    string outcome;
                    try {
                        var t = InsertionTarget.Capture();
                        outcome = "captured: " + (t.CanInsert ? "insertable" : "not insertable: " + t.Refusal);
                        try { outcome += " / insert: " + await t.Insert("fictional words", rig.Owner.Handle, false, CancellationToken.None); }
                        catch (InvalidOperationException error) { outcome += " / insert refused: " + error.Message; }
                    } catch (InvalidOperationException error) { outcome = "refused at the start: " + error.Message; }
                    outcomes.Add(outcome);
                }
                bool untouched = Native.GetClipboardSequenceNumber() == sequence2;
                // The right password, typed as a person would: it opens the file only if the box was still empty.
                await Front(dialogWindow, "password prompt");
                Native.Send(Native.UnicodeText(LockedPassword)); await Task.Delay(300); Keys(0x0D);
                bool openedFile = false;
                for (int i = 0; i < 60 && !openedFile; i++) {
                    await Task.Delay(250);
                    foreach (var p in Process.GetProcessesByName("soffice.bin")) { try { if (p.MainWindowTitle.Contains(Path.GetFileName(copy)) && !p.MainWindowTitle.StartsWith("Password", StringComparison.Ordinal)) openedFile = true; } catch { } }
                }
                Console.WriteLine($"WRITER password: {string.Join(" | ", outcomes)}; clipboard touched={!untouched}; right password then opened the file={openedFile}");
                Check("password prompt: pFlow puts nothing there (clipboard untouched, the right password still opens the file)", untouched && openedFile
                    && outcomes.All(o => o.StartsWith("refused at the start: Dictation is off in password fields", StringComparison.Ordinal) || o.EndsWith(InsertionTarget.SavedToHistory, StringComparison.Ordinal)));
                Check("password prompt: once Writer describes it, pFlow sees a password box and refuses the take", outcomes.Any(o => o.StartsWith("refused at the start: Dictation is off in password fields", StringComparison.Ordinal)));
            }
        } finally {
            foreach (var p in opened) Kill(p);
            foreach (var p in Process.GetProcessesByName("soffice.bin")) { try { if (p.MainWindowTitle.Contains("pflow-fictional")) Kill(p); } catch { } }
            if (hostDirectory != null) { try { QuitHost(hostDirectory); } catch (IOException) { } }
            rig.Preview.Close(); rig.Capsule.Close(); rig.Owner.Dispose(); await rig.Whisper.DisposeAsync();
            await Task.Delay(1000);
            try { Directory.Delete(rig.Directory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            try { Directory.Delete(profile, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
