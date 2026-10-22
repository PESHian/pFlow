using System.Globalization;
using System.Text;

namespace PFlow.Core;

/// What pFlow does with words while the person is still speaking. The labels
/// and saved values match the Mac app (`LiveTextMode.swift`).
public static class LiveTextModes
{
    public const string Off = "off", TypeInApp = "type";
    /// "Preview in pFlow" was a third choice until 2026-10-22; Type mode shows
    /// the same card whenever it cannot type, so a saved preview loads as Type.
    const string RetiredPreview = "preview";
    /// A choice shows its label wherever it is displayed as text.
    public sealed record Choice(string Id, string Title) { public override string ToString() => Title; }
    public static readonly IReadOnlyList<Choice> All = [new(Off, "Off"), new(TypeInApp, "Type in the current app")];

    /// Missing or unknown saved values are Off, so existing installs keep
    /// today's behavior until the person picks something else.
    public static string Resolve(string? value) => value is TypeInApp or RetiredPreview ? TypeInApp : Off;

    /// Typing into the app also shows the card, which says when typing
    /// stopped or the app does not allow it.
    public static bool ShowsPreview(string? value) => Resolve(value) != Off;

    /// Whether the take shows the text card or only the small recording
    /// control. Type mode keeps the control while pFlow is typing in the app:
    /// the words are already on screen there. The card appears only when
    /// typing could not start or has stopped, with its note. The one rule for
    /// both platforms (`LiveTextMode.showsCard` on the Mac).
    public static bool ShowsCard(string? value, bool typingLive) => Resolve(value) != Off && !typingLive;

    public static string Note(string? value) => Resolve(value) switch {
        TypeInApp => "Types your words into the app as you talk, a little behind, and puts in the finished text when you stop. If you move the cursor, type, or switch apps, typing stops and the finished text is saved in History. Apps that don't allow this, such as web browsers, show the preview instead. Template styles such as bold arrive as plain text. Words show about a second behind, and the finished text can differ a little from the preview.",
        _ => "Words appear in your app after you stop talking."
    };
}

/// One step of a take's transcript. `Text` is the whole transcript so far,
/// never an appended chunk. Same shape as the Mac app and the shared fixtures
/// in `fixtures/live-text/transcript-updates`.
public sealed record TranscriptUpdate(string Session, long Sequence, string Text, bool IsFinal);

/// Decides which transcript updates count: drops updates from another take,
/// out of order or repeated updates, and anything after finish or cancel.
public sealed class LiveTranscriptReconciler
{
    public enum Phases { Idle, Open, Final, Cancelled }
    public string? Session { get; private set; }
    public Phases Phase { get; private set; } = Phases.Idle;
    public string Text { get; private set; } = "";
    long? lastSequence;
    /// The newest accepted update. A repeat of the same words still moves it,
    /// which is how the last words settle for live typing.
    public long? LastSequence => lastSequence;

    public void Begin(string session) { Session = session; Phase = Phases.Open; Text = ""; lastSequence = null; }

    /// Applies `update` if it belongs. Returns true when the visible text changed.
    public bool Apply(TranscriptUpdate update)
    {
        if (Phase != Phases.Open || update.Session != Session) return false;
        if (lastSequence is long last && update.Sequence <= last) return false;
        lastSequence = update.Sequence;
        if (update.IsFinal) Phase = Phases.Final;
        if (update.Text == Text) return false;
        Text = update.Text;
        return true;
    }

    public void Cancel() { if (Phase == Phases.Idle) return; Phase = Phases.Cancelled; Text = ""; }
}

public static class LivePreviewText
{
    /// The end of a long transcript, cut at a word so the preview never opens
    /// on half a word. History always keeps the full text; this is display only.
    public static string Tail(string text, int limit = 240)
    {
        string trimmed = text.Trim();
        var starts = StringInfo.ParseCombiningCharacters(trimmed);
        if (starts.Length <= limit) return trimmed;
        int start = starts[starts.Length - limit];
        string tail = trimmed[start..];
        if (!char.IsWhiteSpace(trimmed[start - 1])) {
            int space = tail.ToList().FindIndex(char.IsWhiteSpace);
            if (space >= 0) {
                string rest = tail[space..].Trim();
                if (rest.Length > 0) tail = rest;
            }
        }
        return "…" + tail.Trim();
    }
}

/// Where the live preview goes: centered above the recording control on the
/// display that holds most of the control, below it when there is no room
/// above, and always inside that display's work area. Physical pixels.
public static class LivePreviewPlacement
{
    public static (double X, double Y) Place(IReadOnlyList<WorkArea> areas, WorkArea control, double width, double height, double gap)
    {
        if (areas.Count == 0) throw new ArgumentException("A display work area is required.");
        var area = areas[0]; double best = -1;
        foreach (var candidate in areas) {
            double overlap = Math.Max(0, Math.Min(control.X + control.Width, candidate.X + candidate.Width) - Math.Max(control.X, candidate.X))
                * Math.Max(0, Math.Min(control.Y + control.Height, candidate.Y + candidate.Height) - Math.Max(control.Y, candidate.Y));
            if (overlap > best) { best = overlap; area = candidate; }
        }
        double x = Math.Clamp(control.X + (control.Width - width) / 2, area.X, Math.Max(area.X, area.X + area.Width - width));
        double y = control.Y - gap - height;
        if (y < area.Y) y = control.Y + control.Height + gap;
        y = Math.Clamp(y, area.Y, Math.Max(area.Y, area.Y + area.Height - height));
        return (x, y);
    }
}

/// One Whisper segment from a live window. Times are milliseconds from the
/// start of that window, as Whisper reports them.
public sealed record WhisperWindowSegment(int FromMs, int ToMs, string Text, double NoSpeechProbability);

/// One recognized window of a take, in milliseconds from the start of the
/// take counted in audio samples, never wall-clock time.
public sealed record WhisperWindow(int StartMs, int EndMs, IReadOnlyList<WhisperWindowSegment> Segments);

/// Turns overlapping Whisper windows into one live transcript. Pure logic, a
/// port of the Mac `WhisperLiveMerger`; `fixtures/live-text/whisper-windows/README.md`
/// is the specification both follow. Display only: the finished text of a take
/// always comes from the whole-recording pass.
public sealed class WhisperLiveMerger
{
    public const double NoSpeechLimit = 0.6;
    public const int SettleMs = 1_000;
    public const int OverlapUnits = 8;

    sealed record Piece(int FromMs, int ToMs, string Text);

    /// Words no later window revises.
    public string Committed { get; private set; } = "";
    /// Audio before this point is covered by `Committed`; the next window starts here.
    public int CommittedEndMs { get; private set; }
    List<Piece> tentative = [];
    int lastEndMs;

    public string Text => tentative.Aggregate(Committed, (text, piece) => LiveTextUnits.Join(text, piece.Text));

    /// Applies one window. Returns true when the visible text changed.
    public bool Apply(WhisperWindow window)
    {
        if (window.EndMs <= lastEndMs || window.EndMs <= CommittedEndMs || window.StartMs >= window.EndMs) return false;
        string before = Text;
        lastEndMs = window.EndMs;
        var pieces = new List<Piece>();
        foreach (var segment in window.Segments.Where(IsSpeech)) {
            int from = window.StartMs + Math.Max(0, segment.FromMs);
            int to = Math.Min(window.EndMs, window.StartMs + Math.Max(segment.FromMs, segment.ToMs));
            string text = segment.Text.Trim();
            if (text.Length > 0) pieces.Add(new Piece(Math.Min(from, to), to, text));
        }
        // No later window will hear the audio before this one starts, so the
        // words already shown for it are kept as they are.
        if (window.StartMs > CommittedEndMs) {
            foreach (var piece in tentative) Committed = LiveTextUnits.Join(Committed, Prefix(piece, window.StartMs));
            CommittedEndMs = window.StartMs;
        }
        tentative = [];
        pieces.RemoveAll(piece => piece.ToMs <= CommittedEndMs);
        pieces = DropRepeat(Committed, pieces);
        int index = 0;
        while (index < pieces.Count - 1 && pieces[index].ToMs <= window.EndMs - SettleMs) {
            Committed = LiveTextUnits.Join(Committed, pieces[index].Text);
            CommittedEndMs = Math.Max(CommittedEndMs, pieces[index].ToMs);
            index++;
        }
        tentative = pieces.Skip(index).ToList();
        return Text != before;
    }

    /// Silence and sound labels are not words.
    public static bool IsSpeech(WhisperWindowSegment segment)
    {
        if (!(segment.NoSpeechProbability < NoSpeechLimit)) return false;
        string text = segment.Text.Trim();
        if ((text.StartsWith('[') && text.EndsWith(']')) || (text.StartsWith('(') && text.EndsWith(')'))) return false;
        return text.EnumerateRunes().Any(LiveTextUnits.IsLetterOrNumber);
    }

    static string Prefix(Piece piece, int ms)
    {
        var scalars = piece.Text.EnumerateRunes().ToArray();
        long total = scalars.Length;
        if (total == 0) return "";
        long span = piece.ToMs - piece.FromMs;
        int end = 0;
        foreach (var unit in LiveTextUnits.Units(piece.Text)) {
            if (!(2L * piece.FromMs * total + span * (unit.Start + unit.End) < 2L * ms * total)) break;
            end = unit.End;
        }
        return LiveTextUnits.Slice(scalars, 0, end);
    }

    static List<Piece> DropRepeat(string kept, List<Piece> pieces)
    {
        var keptKeys = LiveTextUnits.Units(kept).Select(unit => unit.Key).Where(key => key.Length > 0).TakeLast(OverlapUnits).ToList();
        var leading = new List<(int Piece, LiveTextUnits.Unit Unit)>();
        for (int index = 0; index < pieces.Count && leading.Count < OverlapUnits; index++)
            foreach (var unit in LiveTextUnits.Units(pieces[index].Text))
                if (unit.Key.Length > 0 && leading.Count < OverlapUnits) leading.Add((index, unit));
        var newKeys = leading.Select(item => item.Unit.Key).ToList();
        int count = 0;
        for (int k = Math.Min(keptKeys.Count, newKeys.Count); k >= 1; k--)
            if (keptKeys.Skip(keptKeys.Count - k).SequenceEqual(newKeys.Take(k))) { count = k; break; }
        if (count == 0) return pieces;
        var cut = leading[count - 1];
        var piece = pieces[cut.Piece];
        var scalars = piece.Text.EnumerateRunes().ToArray();
        // Punctuation left at the cut belongs to the dropped word.
        var rest = LiveTextUnits.Units(piece.Text).FirstOrDefault(unit => unit.Start >= cut.Unit.End && unit.Key.Length > 0);
        string remaining = rest == null ? "" : LiveTextUnits.Slice(scalars, rest.Start, scalars.Length);
        var result = pieces.Skip(cut.Piece + 1).ToList();
        if (remaining.Length > 0) result.Insert(0, piece with { Text = remaining });
        return result;
    }
}

/// Word units used to compare live windows, in Unicode scalar positions so
/// Swift and C# agree. Each Chinese or Japanese character is its own unit.
public static class LiveTextUnits
{
    public sealed record Unit(int Start, int End, string Key);

    public static List<Unit> Units(string text)
    {
        var scalars = text.EnumerateRunes().ToArray();
        var result = new List<Unit>();
        int? start = null;
        void Close(int end) { if (start is int begin) result.Add(new Unit(begin, end, Key(scalars, begin, end))); start = null; }
        for (int index = 0; index < scalars.Length; index++) {
            var scalar = scalars[index];
            if (Rune.IsWhiteSpace(scalar)) Close(index);
            else if (IsIdeographic(scalar)) { Close(index); result.Add(new Unit(index, index + 1, Key(scalars, index, index + 1))); }
            else start ??= index;
        }
        Close(scalars.Length);
        return result;
    }

    /// Joins two pieces with one space, or none where the language or
    /// punctuation does not take one.
    public static string Join(string left, string right)
    {
        string a = left.Trim(), b = right.Trim();
        if (a.Length == 0) return b;
        if (b.Length == 0) return a;
        var last = a.EnumerateRunes().Last();
        var first = Rune.GetRuneAt(b, 0);
        if (IsIdeographic(last) || IsIdeographic(first) || NoSpaceBefore.Contains(first.Value)) return a + b;
        return a + " " + b;
    }

    public static string Slice(Rune[] scalars, int from, int to)
    {
        var builder = new StringBuilder();
        for (int index = from; index < Math.Max(from, to); index++) builder.Append(scalars[index].ToString());
        return builder.ToString().Trim();
    }

    static readonly HashSet<int> NoSpaceBefore = ",.!?;:)]}%…、。，！？：；」』）".EnumerateRunes().Select(rune => rune.Value).ToHashSet();

    public static bool IsIdeographic(Rune scalar) => scalar.Value is (>= 0x3040 and <= 0x30FF) or (>= 0x3400 and <= 0x4DBF)
        or (>= 0x4E00 and <= 0x9FFF) or (>= 0xF900 and <= 0xFAFF) or (>= 0x20000 and <= 0x2FA1F);

    static string Key(Rune[] scalars, int from, int to)
    {
        var builder = new StringBuilder();
        for (int index = from; index < to; index++) if (!IsPunctuation(scalars[index])) builder.Append(scalars[index].ToString());
        return builder.ToString().ToLowerInvariant();
    }

    public static bool IsLetterOrNumber(Rune scalar) => Rune.GetUnicodeCategory(scalar) is UnicodeCategory.UppercaseLetter
        or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
        or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;

    static bool IsPunctuation(Rune scalar) => Rune.GetUnicodeCategory(scalar) is UnicodeCategory.ConnectorPunctuation
        or UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation
        or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation;
}
