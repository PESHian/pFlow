namespace PFlow.Core;

/// pFlow's own live words at the end of a take in a browser field: where they start and exactly what they
/// say. The finished text may go over the field's selection only while that selection is still exactly these
/// words in this place (a page script or a Shift+click can move it after pFlow selected them).
public sealed record OwnedWords(int Start, string Text)
{
    /// Null when the field's one selection is exactly pFlow's words in their place; otherwise why not. A
    /// no-break space counts as a space (browsers show a typed space at a line end as one).
    public string? Mismatch(string fieldText, int selectionStart, int selectionLength)
    {
        if (Text.Length == 0) return "nothing of pFlow's is selected";
        if (selectionStart != Start || selectionLength != Text.Length) return "the selection moved";
        if (Start < 0 || Start + Text.Length > fieldText.Length) return "the field is shorter than pFlow's words";
        return Plain(fieldText.Substring(Start, Text.Length)) == Plain(Text) ? null : "the selected text is not pFlow's words";
    }
    static string Plain(string text) => text.Replace(' ', ' ');
}

/// Places pFlow never types or pastes into, whatever the path: consoles and terminals (a line break runs a
/// command), and remote desktop and virtual machine viewers (the keys go to another computer pFlow cannot
/// check). One list for every path: the checked insert, the paste into an app pFlow cannot read, and the
/// unchecked typing behind a Chromium pane.
public static class NoTypePlaces
{
    /// Window classes: the console host, Windows Terminal, the pseudo-console window, mintty (Git Bash, MSYS2,
    /// Cygwin), ConEmu, PuTTY; Remote Desktop's session window.
    static readonly string[] TerminalClasses = ["ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PseudoConsoleWindow", "mintty", "VirtualConsoleClass", "PuTTY"];
    static readonly string[] RemoteClasses = ["TscShellContainerClass"];
    /// Program names (no .exe).
    static readonly string[] TerminalPrograms = ["WindowsTerminal", "OpenConsole", "conhost", "mintty", "putty", "ConEmu", "ConEmu64", "alacritty", "wezterm-gui"];
    static readonly string[] RemotePrograms = ["mstsc", "msrdc", "vmconnect", "VirtualBoxVM", "vmware", "vmplayer", "vmware-vmx", "vmrc", "remote-viewer", "virt-viewer", "wfica32", "vncviewer", "tvnviewer"];
    /// The element class of a terminal inside an app: xterm.js's input box (VS Code's terminal panel, web terminals).
    static readonly string[] TerminalElements = ["xterm-helper-textarea"];

    public const string Terminal = "pFlow does not type into terminals, where a line break would run a command. Your words are in History.";
    public const string Remote = "pFlow does not type into remote desktop or virtual machine windows. Your words are in History.";
    public const string Elevated = "That app runs as administrator, so Windows does not let pFlow type into it. Your words are in History.";

    /// The refusal for this window, its focused control, its program and the focused element's class, or null.
    public static string? Refusal(string windowClass, string focusedClass, string program, string? elementClass)
    {
        bool Has(string[] list, string? value) => value != null && list.Contains(value, StringComparer.OrdinalIgnoreCase);
        if (Has(TerminalClasses, windowClass) || Has(TerminalClasses, focusedClass) || Has(TerminalPrograms, program)) return Terminal;
        if (elementClass != null && elementClass.Split(' ', StringSplitOptions.RemoveEmptyEntries).Any(part => Has(TerminalElements, part))) return Terminal;
        if (Has(RemoteClasses, windowClass) || Has(RemoteClasses, focusedClass) || Has(RemotePrograms, program)) return Remote;
        return null;
    }
}

/// What pFlow found out about the focused field of an app UI Automation cannot read, and the one decision
/// over it (WeakField). MSAA role and state are the raw numbers.
public readonly record struct WeakFacts(bool Chromium, bool UiaPassword, bool MsaaFound, bool MsaaChild, int Role, int State, bool Scintilla, bool ScintillaReadOnly,
    bool AccessibleText, bool UiaEditable, int Selections);

public enum WeakKind { Accessible, Scintilla, PasteOnly }

public static class WeakFieldRule
{
    public const int RoleText = 42, RoleDocument = 15;
    public const string InChromium = "a Chromium window";
    public const int StateUnavailable = 0x1, StateFocused = 0x4, StateReadOnly = 0x40, StateFocusable = 0x100000, StateProtected = 0x20000000;

    /// Password (refuse the take), a kind pFlow can write to, or null with the reason. Never in a Chromium
    /// window (browsers and Electron apps keep their own path); never with more than one caret or selection,
    /// since a paste would land at each one and the result could not be checked.
    public static (WeakKind? Kind, bool Password, string Why) Decide(WeakFacts f)
    {
        if (f.Chromium) return (null, false, InChromium);
        if (f.UiaPassword || (f.State & StateProtected) != 0) return (null, true, "password");
        if (f.Selections > 1) return (null, false, "more than one caret or selection");
        bool usable = (f.State & (StateUnavailable | StateReadOnly)) == 0;
        if (f.Scintilla) return f.ScintillaReadOnly ? (null, false, "Scintilla: read-only") : (WeakKind.Scintilla, false, "ok");
        if (f.MsaaFound && !f.MsaaChild && (f.State & StateFocused) != 0 && usable && f.AccessibleText) return (WeakKind.Accessible, false, "ok");
        bool msaaEditable = f.MsaaFound && f.Role is RoleText or RoleDocument && (f.State & (StateFocused | StateFocusable)) == (StateFocused | StateFocusable) && usable;
        if (msaaEditable || f.UiaEditable) return (WeakKind.PasteOnly, false, "ok");
        return (null, false, "not an editable field (MSAA role " + f.Role + ", state 0x" + f.State.ToString("x") + ")");
    }
}

/// A total time limit for a run of calls into another app (each one a cross-process call on pFlow's UI
/// thread): once it is over, the caller stops and says it could not check, or refuses.
public sealed class CallDeadline(int milliseconds, Func<long>? clock = null)
{
    public const int Default = 300;
    readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    long? end;
    public bool Over { get { long t = now(); end ??= t + milliseconds; return t > end; } }
    /// Starts the clock now (otherwise it starts at the first look).
    public CallDeadline Start() { _ = Over; return this; }
}

public static class AccessibleWalk
{
    /// The deepest descendant whose state says focused, at most `depth` levels and `budget` objects down,
    /// stopping when the deadline is over (then `stopped` is true and the result is null: nothing is known).
    public static T? FocusedBelow<T>(T parent, Func<T, IReadOnlyList<T>?> children, Func<T, bool> focused, CallDeadline deadline, out bool stopped, int depth = 8, int budget = 400) where T : class
    {
        stopped = false;
        var found = Walk(parent, children, focused, deadline, depth, ref budget, ref stopped);
        return stopped ? null : found;
    }

    static T? Walk<T>(T parent, Func<T, IReadOnlyList<T>?> children, Func<T, bool> focused, CallDeadline deadline, int depth, ref int budget, ref bool stopped) where T : class
    {
        if (depth <= 0 || budget <= 0) return null;
        if (deadline.Over) { stopped = true; return null; }
        var list = children(parent);
        if (list == null) return null;
        foreach (var child in list) {
            if (deadline.Over) { stopped = true; return null; }
            if (--budget <= 0) return null;
            if (focused(child)) return Walk(child, children, focused, deadline, depth - 1, ref budget, ref stopped) ?? (stopped ? null : child);
            if (Walk(child, children, focused, deadline, depth - 1, ref budget, ref stopped) is { } deeper) return deeper;
            if (stopped) return null;
        }
        return null;
    }
}
