using System.Globalization;
using System.Text;

namespace PFlow.Core;

/// A range in a text field, in UTF-16 code units, the unit .NET strings, UI
/// Automation text and Win32 edit controls use.
public readonly record struct TextSpan(int Start, int Length)
{
    public int End => Start + Length;
}

/// What a live-typing take sees in the destination at one moment. Same shape
/// as the Mac app (`LiveFieldState`) and the shared fixtures in
/// `fixtures/live-text/inline-ownership`.
public sealed record LiveFieldState(long App, string Element, bool Secure, bool Trusted, string? Value, TextSpan? Selection)
{
    /// The element value while the captured field still has focus.
    public const string Target = "target";
}

/// Why live typing did not start or stopped for the take. The names match the
/// fixtures' `beginResult` and `reason` strings in lower case.
public enum LiveStop { Unsupported, Permission, App, Focus, Secure, Text, Caret, Uncertain }

/// One decision of the ownership rules: write nothing, make one write, or stop.
public abstract record LiveStep
{
    public static readonly LiveStep None = new Nothing();
    public sealed record Nothing : LiveStep;
    /// Replace `Range` with `Text`, then set the selection to `Select`, or leave the caret after `Text`.
    public sealed record Write(TextSpan Range, string Text, TextSpan? Select) : LiveStep;
    public sealed record Stopped(LiveStop Reason) : LiveStep;
}

/// Words two consecutive transcript updates agree on. A recognizer may still
/// change its newest words, and Whisper's first window sometimes invents a
/// phrase that the next window drops, so only agreed words are typed live.
/// Port of the Mac `LiveStableText`: characters are grapheme clusters,
/// compared code unit by code unit.
public static class LiveStableText
{
    public static string Agreed(string? previous, string current)
    {
        if (previous == null) return "";
        string[] old = Characters(previous), now = Characters(current);
        int count = 0;
        while (count < old.Length && count < now.Length && old[count] == now[count]) count++;
        if (count == old.Length && count == now.Length) return current.Trim();
        // Cut back to a point where a word has ended in both updates.
        while (count > 0 && !(EndsWord(old, count, true) && EndsWord(now, count, false))) count--;
        return string.Concat(now.Take(count)).Trim();
    }

    /// True when `prefix` is all of `text` or stops where a word ends.
    public static bool StartsWithWholeWords(string text, string prefix)
    {
        string[] characters = Characters(text), head = Characters(prefix);
        if (head.Length > characters.Length || !head.Zip(characters).All(pair => pair.First == pair.Second)) return false;
        return EndsWord(characters, head.Length, true);
    }

    /// The text's user-perceived characters (extended grapheme clusters), like Swift's `Character`.
    public static string[] Characters(string text)
    {
        var result = new List<string>(text.Length);
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext()) result.Add(elements.GetTextElement());
        return [.. result];
    }

    static bool EndsWord(string[] characters, int index, bool endIsBoundary)
    {
        if (index == characters.Length) return endIsBoundary;
        string next = characters[index];
        // An apostrophe or hyphen may continue the word ("don't", "follow-up").
        bool joins = next is "'" or "’" or "-" or "‐";
        if (IsWhitespace(next) || (IsPunctuation(next) && !joins) || InsertionSpacing.UsesUnspacedScript(next)) return true;
        return index > 0 && (IsWhitespace(characters[index - 1]) || InsertionSpacing.UsesUnspacedScript(characters[index - 1]));
    }

    static Rune First(string character) => Rune.GetRuneAt(character, 0);
    static bool IsWhitespace(string character) => Rune.IsWhiteSpace(First(character));
    static bool IsPunctuation(string character) => Rune.GetUnicodeCategory(First(character)) is UnicodeCategory.ConnectorPunctuation
        or UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation
        or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation;
}

/// The ownership rules for typing a take into another app while it is spoken.
/// Pure: it decides what to write and checks what it observed; the caller
/// performs the write with a native text-range operation and reports back.
/// pFlow owns exactly one span, starting at the person's caret or selection.
/// Anything outside that span, or any change pFlow did not make, stops live
/// typing for the take, and nothing is ever retried. Port of the Mac
/// `LiveInlineOwnership`; both run the shared fixtures.
public sealed class LiveInlineOwnership
{
    /// Longest field, in UTF-16 units, read on every update. Longer fields use Preview.
    public const int MaxFieldLength = 100_000;

    readonly long app;
    readonly string before, after;
    public TextSpan Original { get; }
    public string OriginalSelected { get; }
    /// Exactly what the owned span holds now.
    public string Owned { get; private set; }
    public TextSpan Caret { get; private set; }
    public LiveStop? Stopped { get; private set; }
    /// A write was attempted, so the destination may hold pFlow's text.
    public bool Touched { get; private set; }
    string typedWords = "";
    string? previous;
    (string Owned, string Words, TextSpan Caret)? pending;

    LiveInlineOwnership(long app, string value, TextSpan selection)
    {
        this.app = app;
        before = value[..selection.Start];
        after = value[selection.End..];
        Original = selection;
        OriginalSelected = value.Substring(selection.Start, selection.Length);
        Owned = OriginalSelected;
        Caret = selection;
    }

    /// Checks the destination captured before any pFlow window appeared.
    /// `writable` is the native probe, made without writing anything.
    public static LiveInlineOwnership? Begin(LiveFieldState state, bool writable, out LiveStop? refused)
    {
        refused = !state.Trusted ? LiveStop.Permission : state.Secure ? LiveStop.Secure : null;
        if (refused != null) return null;
        if (!writable || state.Element != LiveFieldState.Target || state.Value is not string value || value.Length > MaxFieldLength
            || state.Selection is not TextSpan selection || selection.Start < 0 || selection.Length < 0 || selection.End > value.Length
            || SplitsCharacter(value, selection.Start) || SplitsCharacter(value, selection.End)) {
            refused = LiveStop.Unsupported;
            return null;
        }
        return new LiveInlineOwnership(state.App, value, selection);
    }

    /// A position between the two halves of a surrogate pair is not a place text can go.
    static bool SplitsCharacter(string value, int position) =>
        position > 0 && position < value.Length && char.IsHighSurrogate(value[position - 1]) && char.IsLowSurrogate(value[position]);

    public string ExpectedValue => before + Owned + after;

    /// The first reason the destination is no longer exactly as pFlow left it.
    public LiveStop? Check(LiveFieldState state)
    {
        if (!state.Trusted) return LiveStop.Permission;
        if (state.App != app) return LiveStop.App;
        if (state.Element != LiveFieldState.Target) return LiveStop.Focus;
        if (state.Secure) return LiveStop.Secure;
        if (state.Value == null || !string.Equals(state.Value, ExpectedValue, StringComparison.Ordinal)) return LiveStop.Text;
        if (state.Selection != Caret) return LiveStop.Caret;
        return null;
    }

    /// A new whole transcript arrived. Returns the one write to make, if any.
    public LiveStep Update(string transcript, LiveFieldState state)
    {
        if (Stopped != null || pending != null) return LiveStep.None;
        if (Check(state) is LiveStop reason) return Stop(reason);
        string words = LiveStableText.Agreed(previous, transcript);
        previous = transcript;
        string spoken = transcript.Trim();
        // Keep what is typed while the newest words still begin with it,
        // so a recognizer that hesitates over its last word causes no flicker.
        if (Length(words) <= Length(typedWords) && LiveStableText.StartsWithWholeWords(spoken, typedWords)) return LiveStep.None;
        if (words.Length == 0 && !Touched) return LiveStep.None;
        return Plan(words, Spaced(words));
    }

    /// The finished, cleaned text replaces the owned span once.
    public LiveStep Finalize(string text, LiveFieldState state)
    {
        if (Stopped is LiveStop stopped) return new LiveStep.Stopped(stopped);
        if (pending != null) return Stop(LiveStop.Uncertain);
        if (Check(state) is LiveStop reason) return Stop(reason);
        return Plan(text, Spaced(text));
    }

    /// Takes pFlow's text back out, only while everything is exactly as pFlow
    /// left it. Never after an uncertain write, never over a later edit.
    public LiveStep Cancel(LiveFieldState state)
    {
        if (!Touched && pending == null) return LiveStep.None;
        if (Stopped == LiveStop.Uncertain || pending != null) return new LiveStep.Stopped(LiveStop.Uncertain);
        if (Check(state) is LiveStop reason) return new LiveStep.Stopped(reason);
        if (string.Equals(Owned, OriginalSelected, StringComparison.Ordinal) && Caret == Original) return LiveStep.None;
        pending = (OriginalSelected, "", Original);
        return new LiveStep.Write(new TextSpan(Original.Start, Owned.Length), OriginalSelected, Original);
    }

    /// Reports how the write went and what the field shows now. Anything but
    /// the exact expected result ends live typing for the take.
    public LiveStep Confirm(bool accepted, LiveFieldState state)
    {
        if (pending is not { } written) return LiveStep.None;
        var (owned, words, caret) = written;
        pending = null;
        Touched = true;
        string expected = before + owned + after;
        if (!accepted || !state.Trusted || state.App != app || state.Element != LiveFieldState.Target || state.Secure
            || !string.Equals(state.Value, expected, StringComparison.Ordinal) || state.Selection != caret) return Stop(LiveStop.Uncertain);
        Owned = owned; typedWords = words; Caret = caret;
        return LiveStep.None;
    }

    LiveStep Stop(LiveStop reason)
    {
        Stopped = reason;
        return new LiveStep.Stopped(reason);
    }

    static int Length(string text) => new StringInfo(text).LengthInTextElements;

    string Spaced(string words) => words.Length == 0 ? ""
        : InsertionSpacing.AtCaret(words, before + OriginalSelected + after, Original.Start, Original.Length).Apply(words);

    /// The smallest replacement from the first differing character to the end
    /// of the owned span, so the caret ends after pFlow's text.
    LiveStep Plan(string words, string target)
    {
        if (string.Equals(Owned, target, StringComparison.Ordinal)) return LiveStep.None;
        string[] old = LiveStableText.Characters(Owned), now = LiveStableText.Characters(target);
        int shared = 0, units = 0;
        while (shared < old.Length && shared < now.Length && old[shared] == now[shared]) { units += old[shared].Length; shared++; }
        string replacement = string.Concat(now.Skip(shared));
        int start = Original.Start;
        pending = (target, words, new TextSpan(start + target.Length, 0));
        return new LiveStep.Write(new TextSpan(start + units, Owned.Length - units), replacement, null);
    }
}

/// A text field pFlow may type into while a take is spoken. The real one is a
/// Win32 edit or rich edit control in another app; tests use their own.
public interface ILiveTextField
{
    LiveFieldState State();
    /// Whether text ranges can be selected and replaced here at all. Checked
    /// once at begin without writing anything.
    bool CanWriteRanges();
    /// Selects `range` and replaces it with `text` through a native text-range
    /// operation, never with keys or the clipboard.
    bool Replace(TextSpan range, string text);
    bool Select(TextSpan range);
    /// The line break the field stores: "\r\n" for an edit control, "\r" for rich edit.
    string LineBreak { get; }
}

public enum LiveFinal { Applied, NotTyped, Kept }
public enum LiveCancel { NothingTyped, Removed, Left }

/// One take's live typing: the ownership rules applied to one real field.
/// Writes happen one at a time on the caller's thread and are read back
/// before the next. The first failure ends typing for the take.
public sealed class LiveInlineSession
{
    public string Id { get; }
    readonly ILiveTextField field;
    readonly LiveInlineOwnership ownership;

    LiveInlineSession(string id, ILiveTextField field, LiveInlineOwnership ownership) { Id = id; this.field = field; this.ownership = ownership; }

    public static LiveInlineSession? Begin(string id, ILiveTextField field, out LiveStop? refused)
    {
        var state = field.State();
        bool writable = state.Selection != null && field.CanWriteRanges();
        var ownership = LiveInlineOwnership.Begin(state, writable, out refused);
        return ownership == null ? null : new LiveInlineSession(id, field, ownership);
    }

    public LiveStop? Stopped => ownership.Stopped;
    public bool Touched => ownership.Touched;

    /// Applies the newest transcript. Returns the reason when typing stops now.
    public LiveStop? Update(string transcript)
    {
        // Once typing has stopped for the take, the field is not read again.
        if (ownership.Stopped != null) return null;
        return Perform(ownership.Update(LineBreaks(transcript), field.State()));
    }

    public (LiveFinal Result, LiveStop? Stop) Finalize(string text)
    {
        if (ownership.Stopped != null && !ownership.Touched) return (LiveFinal.NotTyped, null);
        return Perform(ownership.Finalize(LineBreaks(text), field.State())) is LiveStop stop ? (LiveFinal.Kept, stop) : (LiveFinal.Applied, null);
    }

    public (LiveCancel Result, LiveStop? Stop) Cancel()
    {
        if (!ownership.Touched) return (LiveCancel.NothingTyped, null);
        return Perform(ownership.Cancel(field.State())) is LiveStop stop ? (LiveCancel.Left, stop) : (LiveCancel.Removed, null);
    }

    /// Every line break in pFlow's words is the one the field itself stores,
    /// so what is read back can be compared exactly.
    string LineBreaks(string text) => LiveInlineText.LineBreaks(text, field.LineBreak);

    LiveStop? Perform(LiveStep step)
    {
        switch (step) {
            case LiveStep.Stopped stopped: return stopped.Reason;
            case LiveStep.Write write:
                bool accepted = field.Replace(write.Range, write.Text);
                if (accepted && write.Select is TextSpan select) accepted = field.Select(select);
                return ownership.Confirm(accepted, field.State()) is LiveStep.Stopped failed ? failed.Reason : null;
            default: return null;
        }
    }
}

/// Holds at most one take's live typing. A call for any other take is
/// ignored, and finalize or cancel ends the take, so a late or stale call can
/// never write.
public sealed class LiveInlineSlot
{
    LiveInlineSession? current;

    public bool Active => current != null;
    /// pFlow's words may be in the destination for the current take.
    public bool Typed(string session) => current is { } live && live.Id == session && live.Touched;

    /// Returns null when typing starts, or the reason the take uses Preview.
    public LiveStop? Begin(string id, ILiveTextField? field)
    {
        current = null;
        if (field == null) return LiveStop.Unsupported;
        current = LiveInlineSession.Begin(id, field, out var refused);
        return refused;
    }

    public LiveStop? Reconcile(string session, string transcript) =>
        current is { } live && live.Id == session ? live.Update(transcript) : null;

    public (LiveFinal Result, LiveStop? Stop) Finalize(string session, string text)
    {
        if (current is not { } live || live.Id != session) return (LiveFinal.NotTyped, null);
        current = null;
        return live.Finalize(text);
    }

    public (LiveCancel Result, LiveStop? Stop) Cancel(string session)
    {
        if (current is not { } live || live.Id != session) return (LiveCancel.NothingTyped, null);
        current = null;
        return live.Cancel();
    }

    /// Ends the take without writing anything more; typed words stay where they are.
    public void Abandon() => current = null;
}

/// The plain words shown for live typing. Short enough for one line of the preview.
public static class LiveInlineText
{
    public static string LineBreaks(string text, string lineBreak) =>
        text.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", lineBreak);

    /// Shown in the preview while pFlow types into the app, named the way the
    /// app names itself (its file description, then its product name), else by
    /// its program file name. Never the window title, which can name a document.
    public static string TypingNote(string? description, string? product, string program)
    {
        static string? Clean(string? name)
        {
            if (name == null) return null;
            string text = new string(name.Where(c => !char.IsControl(c)).ToArray()).Trim();
            return text.Length == 0 ? null : text.Length <= 60 ? text : text[..60].TrimEnd() + "…";
        }
        return "Typing in " + (Clean(description) ?? Clean(product) ?? Clean(program) ?? "this app");
    }

    /// Shown in the preview when typing could not start, so the take is Preview only.
    public static string PreviewNote(LiveStop stop) => stop switch {
        LiveStop.Permission => "Can't type in an admin app",
        LiveStop.Secure => "Password field",
        _ => "Can't type here live. Words go in when you stop"
    };

    /// Shown in the preview when typing stops partway through a take.
    public static string StoppedNote(LiveStop stop) => stop switch {
        LiveStop.Permission => "Stopped: no permission",
        LiveStop.App => "Stopped: app changed",
        LiveStop.Focus => "Stopped: field changed",
        LiveStop.Secure => "Stopped: password field",
        LiveStop.Text => "Stopped: text changed",
        LiveStop.Caret => "Stopped: cursor moved",
        _ => "Stopped: couldn't check"
    };

    /// The finished text could not be put in safely; it is in History.
    public static string Kept(LiveStop stop) => "Live typing stopped because " + stop switch {
        LiveStop.Permission => "pFlow can't type in that app",
        LiveStop.App => "you switched apps",
        LiveStop.Focus => "you switched fields",
        LiveStop.Secure => "a password field took over",
        LiveStop.Text => "the text changed",
        LiveStop.Caret => "the cursor moved",
        _ => "pFlow couldn't check what it typed"
    } + ". The finished text is in History.";

    public const string Left = "Canceled. The words pFlow already typed are still in your app, because the field changed.";
    public const string KeptTyped = "Kept in History. Recognition stopped before it finished; the words already typed stay in your app.";
}
