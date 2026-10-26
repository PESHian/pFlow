using PFlow.Core;

// W028 fix round 1: the rules the risky insert paths share, without any live app. The end-of-take replace's
// selection check; the decision for apps UI Automation cannot read (password, Chromium, multi-caret); the
// places pFlow never types into; "exactly once more" in what an app shows; the deadline on calls into an app.
internal static class InsertionRuleChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static void Run()
    {
        passed = 0;
        // The replace: the selection must still be exactly pFlow's own words, in their place.
        var own = new OwnedWords(18, "harbor lights");
        const string field = "Fictional prefix. harbor lights";
        Check("replace: the selection still exactly pFlow's words is allowed", own.Mismatch(field, 18, 13) == null);
        Check("replace: a no-break space in the field reads as a space", new OwnedWords(18, "harbor lights").Mismatch("Fictional prefix. harbor lights", 18, 13) == null);
        Check("replace: a selection grown over the person's text (Shift+click) is refused", own.Mismatch(field, 16, 15) != null);
        Check("replace: a selection moved to other words of the same length is refused", own.Mismatch("Fictional prefix. harbor lights", 0, 13) != null);
        Check("replace: the same place with other text (a script rewrote it) is refused", own.Mismatch("Fictional prefix. harbor nights", 18, 13) != null);
        Check("replace: a collapsed or shrunk selection is refused", own.Mismatch(field, 18, 0) != null && own.Mismatch(field, 18, 12) != null);
        Check("replace: a field shorter than pFlow's words is refused", own.Mismatch("Fictional prefix. harbor", 18, 13) != null);
        // Fix round 2: the person's own key or click after pFlow's selection (UI Automation may still report the old one).
        Check("replace: nobody watched the person's input, so it counts as interrupted", own.Interrupted() && (own with { PersonActed = () => true }).Interrupted()
            && !(own with { PersonActed = () => false }).Interrupted());
        Check("person input: a key or a mouse button going down counts", PersonInput.Counts(PersonInput.KeyDown, false, false) && PersonInput.Counts(PersonInput.SystemKeyDown, false, false)
            && PersonInput.Counts(PersonInput.LeftDown, false, false) && PersonInput.Counts(PersonInput.RightDown, false, false) && PersonInput.Counts(PersonInput.MiddleDown, false, false)
            && PersonInput.Counts(PersonInput.ExtraDown, false, false));
        Check("person input: the pointer moving, the wheel, a key or button coming up do not count", !PersonInput.Counts(0x200, false, false) && !PersonInput.Counts(0x20A, false, false)
            && !PersonInput.Counts(0x20E, false, false) && !PersonInput.Counts(0x101, false, false) && !PersonInput.Counts(0x105, false, false) && !PersonInput.Counts(0x202, false, false));
        Check("person input: a program's injected keys and clicks (pFlow's own) and the activation key do not count",
            !PersonInput.Counts(PersonInput.KeyDown, true, false) && !PersonInput.Counts(PersonInput.LeftDown, true, false) && !PersonInput.Counts(PersonInput.KeyDown, false, true));
        Check("input panels: a candidate list (200 px) or the emoji panel (360 px) on a 1728 px screen counts", InputPanels.Counts(true, true, false, 200, 263, 1728) && InputPanels.Counts(true, true, false, 360, 400, 1728));
        Check("input panels: hidden (cloaked or not visible), empty, another app's window or the touch keyboard (923 px) do not count",
            !InputPanels.Counts(true, true, true, 200, 263, 1728) && !InputPanels.Counts(true, false, false, 200, 263, 1728) && !InputPanels.Counts(true, true, false, 0, 0, 1728)
            && !InputPanels.Counts(false, true, false, 200, 263, 1728) && !InputPanels.Counts(true, true, false, 923, 544, 1728) && !InputPanels.Counts(true, true, false, 1728, 400, 1728));

        // Apps UI Automation cannot read.
        var paste = new WeakFacts(false, false, true, false, WeakFieldRule.RoleText, WeakFieldRule.StateFocused | WeakFieldRule.StateFocusable, false, false, false, false, 0);
        Check("weak field: an editable MSAA text field pFlow cannot read is pasted into (PasteOnly)", WeakFieldRule.Decide(paste) is (WeakKind.PasteOnly, false, _));
        Check("weak field: a password through UI Automation IsPassword is refused", WeakFieldRule.Decide(paste with { UiaPassword = true }) is (null, true, _));
        Check("weak field: a password through MSAA PROTECTED is refused", WeakFieldRule.Decide(paste with { State = paste.State | WeakFieldRule.StateProtected }) is (null, true, _));
        Check("weak field: PROTECTED refuses even a readable IAccessible2 field or Scintilla", WeakFieldRule.Decide(paste with { AccessibleText = true, State = paste.State | WeakFieldRule.StateProtected }).Password
            && WeakFieldRule.Decide(paste with { Scintilla = true, UiaPassword = true }).Password);
        Check("weak field: never in a Chromium window", WeakFieldRule.Decide(paste with { Chromium = true }).Kind == null && WeakFieldRule.Decide(paste with { Chromium = true, UiaEditable = true }).Kind == null);
        Check("weak field: read-only or unavailable is not pasted into", WeakFieldRule.Decide(paste with { State = paste.State | WeakFieldRule.StateReadOnly }).Kind == null
            && WeakFieldRule.Decide(paste with { State = paste.State | WeakFieldRule.StateUnavailable }).Kind == null);
        Check("weak field: an MSAA object that is not a text field, and no UI Automation edit, is not pasted into", WeakFieldRule.Decide(paste with { Role = 10 }).Kind == null);
        Check("weak field: a focused UI Automation edit or document is enough for PasteOnly", WeakFieldRule.Decide(paste with { MsaaFound = false, UiaEditable = true }).Kind == WeakKind.PasteOnly);
        Check("weak field: IAccessible2 text on the focused object is read and checked (Accessible)", WeakFieldRule.Decide(paste with { AccessibleText = true }).Kind == WeakKind.Accessible);
        Check("weak field: Scintilla is read through its own messages, unless read-only", WeakFieldRule.Decide(paste with { Scintilla = true }).Kind == WeakKind.Scintilla
            && WeakFieldRule.Decide(paste with { Scintilla = true, ScintillaReadOnly = true }).Kind == null);
        Check("weak field: more than one caret or selection is refused (a paste would land at each)", WeakFieldRule.Decide(paste with { Scintilla = true, Selections = 2 }).Kind == null
            && WeakFieldRule.Decide(paste with { AccessibleText = true, Selections = 2 }).Kind == null && WeakFieldRule.Decide(paste with { Scintilla = true, Selections = 1 }).Kind == WeakKind.Scintilla);

        // Places pFlow never types into, whatever the path.
        Check("no-type places: consoles and terminals by window class", new[] { "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PseudoConsoleWindow", "mintty", "VirtualConsoleClass", "PuTTY" }
            .All(c => NoTypePlaces.Refusal(c, "", "fictional", null) == NoTypePlaces.Terminal));
        Check("no-type places: a terminal's focused control or its program", NoTypePlaces.Refusal("Fictional", "PseudoConsoleWindow", "fictional", null) == NoTypePlaces.Terminal
            && NoTypePlaces.Refusal("Fictional", "", "WindowsTerminal", null) == NoTypePlaces.Terminal && NoTypePlaces.Refusal("Fictional", "", "windowsterminal", null) == NoTypePlaces.Terminal);
        Check("no-type places: the terminal panel inside VS Code (xterm.js's input box)", NoTypePlaces.Refusal("Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND", "Code", "xterm-helper-textarea") == NoTypePlaces.Terminal
            && NoTypePlaces.Refusal("Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND", "Code", "inputarea monaco-mouse-cursor-text") == null);
        Check("no-type places: Remote Desktop and virtual machine viewers", NoTypePlaces.Refusal("TscShellContainerClass", "", "mstsc", null) == NoTypePlaces.Remote
            && new[] { "msrdc", "vmconnect", "VirtualBoxVM", "vmware", "vmplayer", "remote-viewer", "virt-viewer", "wfica32", "vncviewer" }.All(p => NoTypePlaces.Refusal("Fictional", "", p, null) == NoTypePlaces.Remote));
        Check("no-type places: ordinary apps are not refused (Notepad, Writer, Notepad++, Chrome, Edge, Word, PowerShell ISE's editor)",
            NoTypePlaces.Refusal("Notepad", "RichEditD2DPT", "Notepad", "RichEditD2DPT") == null && NoTypePlaces.Refusal("SALFRAME", "SALFRAME", "soffice.bin", "") == null
            && NoTypePlaces.Refusal("Notepad++", "Scintilla", "notepad++", "Scintilla") == null && NoTypePlaces.Refusal("Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND", "chrome", "") == null
            && NoTypePlaces.Refusal("Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND", "msedge", "") == null && NoTypePlaces.Refusal("OpusApp", "_WwG", "WINWORD", "_WwG") == null
            && NoTypePlaces.Refusal("HwndWrapper[PowerShell_ISE.exe;;fictional]", "", "powershell_ise", "") == null);
        Check("no-type places: every refusal goes to the Copy card", InsertionPrompt.Needed(NoTypePlaces.Terminal, false) && InsertionPrompt.Needed(NoTypePlaces.Remote, false) && InsertionPrompt.Needed(NoTypePlaces.Elevated, false)
            && InsertionPrompt.Reason(NoTypePlaces.Terminal) == "pFlow does not type into terminals, where a line break would run a command.");
        Check("a busy clipboard refuses the paste and shows the Copy card with a plain reason", InsertionPrompt.Needed("The clipboard is busy. Your text is in History.", false)
            && InsertionPrompt.Reason("The clipboard is busy. Your text is in History.") == "Another app was holding the clipboard, so pFlow did not paste.");

        // What an app shows: the words landed exactly once more, never twice (two carets).
        Check("shown text: two more copies (a paste at two carets) is not landed", !ShownText.Landed("a\na", "aX\naX", "aX") && ShownText.Landed("a\na", "aX\na", "aX"));
        Check("shown text: one more than an existing copy still counts", ShownText.Landed("aX\na", "aX\naX", "aX") && !ShownText.Landed("aX\na", "aX\naX\naX", "aX"));

        // The deadline on calls into an app: a slow app stops the walk, and nothing is claimed.
        {
            long now = 0;
            var tree = new Dictionary<string, string[]> { ["root"] = ["a", "b", "c", "d"], ["a"] = ["a1", "a2"], ["b"] = ["b1"], ["c"] = ["c1", "c2", "c3"], ["d"] = ["focused"] };
            IReadOnlyList<string>? Kids(string n) { now += 40; return tree.TryGetValue(n, out var k) ? k : []; }
            var deadline = new CallDeadline(CallDeadline.Default, () => now).Start();
            var found = AccessibleWalk.FocusedBelow("root", Kids, n => n == "focused", deadline, out bool stopped);
            Check("deadline: a slow app (40 ms a call) stops the focus walk at 300 ms and nothing is found or claimed", stopped && found == null && now <= 360);
            now = 0;
            var quick = AccessibleWalk.FocusedBelow("root", n => tree.TryGetValue(n, out var k) ? k : [], n => n == "focused", new CallDeadline(CallDeadline.Default, () => now).Start(), out bool quickStopped);
            Check("deadline: a quick app's focused object is found", !quickStopped && quick == "focused");
            var clockless = new CallDeadline(10, () => now).Start(); now = 11;
            Check("deadline: over once its time is up", clockless.Over);
            var budget = new CallDeadline(CallDeadline.Default, () => now).Start(); now += 120;
            uint left = budget.Remaining; now += 180; uint last = budget.Remaining; now += 1;
            Check("deadline: a call's own timeout is what is left of the limit (180 ms after 120, at least 1 ms at the end, 0 once over)", left == 180 && last == 1 && budget.Remaining == 0);
        }
        Console.WriteLine($"{passed} insertion rule checks passed.");
    }
}
