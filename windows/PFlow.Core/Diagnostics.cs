using System.Globalization;
using System.Text;

namespace PFlow.Core;

/// One fact in a diagnostic event: a number, yes/no, a reason name or a short label (a process name,
/// a control class). Never words a person said or typed, a window title, the clipboard or a path.
public readonly record struct DiagField(string Key, object? Value);

/// What pFlow did during the last takes, kept in memory only, for "Save a diagnostic report". Each take
/// keeps its events with the milliseconds since the take began; app events (a speech worker start, a
/// settings change) keep the milliseconds since pFlow started. Bounded: the last `MaxTakes` takes and
/// about `MaxChars` characters in all, so memory never grows with use. Every value goes through
/// `Value`: paths are replaced (PrivateLog.Scrub), control characters become spaces and long values
/// are cut, so even a caller's mistake cannot put a paragraph of text in the report.
/// `Event` lines are also written to insertion.log through `Compact`; `Detail` lines (one per live window,
/// update or write) go to the report only, and the take's summary line counts them.
public sealed class DiagnosticRecorder
{
    public const int MaxTakes = 20, MaxEventsPerTake = 4000, MaxAppEvents = 400, MaxValueLength = 160, MaxLogLength = 300;
    public const long MaxChars = 2_000_000;

    sealed class Take(int number, DateTimeOffset started, long startMs)
    {
        public readonly int Number = number;
        public readonly DateTimeOffset Started = started;
        public readonly long StartMs = startMs;
        public readonly List<string> Lines = [];
        public readonly SortedDictionary<string, int> Counts = new(StringComparer.Ordinal);
        public long Chars;
        public int Dropped;
        public bool Ended;
    }

    readonly object sync = new();
    readonly Func<long> clock;
    readonly Func<DateTimeOffset> now;
    readonly long appStartMs;
    readonly LinkedList<Take> takes = new();
    readonly LinkedList<string> app = new();
    long chars;
    int nextTake = 1;
    Take? current;

    /// A compact line for the private insertion.log (never the report's detail lines).
    public Action<string>? Compact { get; set; }

    public DiagnosticRecorder(Func<long>? clock = null, Func<DateTimeOffset>? now = null)
    {
        this.clock = clock ?? (() => Environment.TickCount64);
        this.now = now ?? (() => DateTimeOffset.Now);
        appStartMs = this.clock();
    }

    /// The take now starting; earlier takes beyond `MaxTakes` are forgotten. Returns its number.
    public int BeginTake(params DiagField[] fields)
    {
        string line;
        int number;
        lock (sync) {
            if (current is { Ended: false } open) Close(open, [new("ended", "a new take began")]);
            var take = new Take(nextTake++, now(), clock());
            takes.AddLast(take); current = take; number = take.Number;
            while (takes.Count > MaxTakes) Forget(takes.First!.Value);
            line = Append(take, "take.start", fields, compact: true);
        }
        Compact?.Invoke(line);
        return number;
    }

    /// A decision worth seeing in insertion.log too (capture, typing began or not, why live words stopped).
    public void Event(string name, params DiagField[] fields) => Add(name, fields, compact: true);

    /// A frequent step (a live window, an update, a write): in the report only, counted in the take's summary.
    public void Detail(string name, params DiagField[] fields) => Add(name, fields, compact: false);

    /// A line pFlow wrote to insertion.log, kept with the take it belongs to. Never echoed back to the log.
    public void Log(string line)
    {
        lock (sync) {
            string clean = Value(line, MaxLogLength);
            if (current is { Ended: false } take) Append(take, "log", [new("line", null)], compact: false, raw: clean);
            else AppLine("log " + clean);
        }
    }

    /// The take is over; its summary (how many windows, updates, writes and stops) goes to insertion.log.
    public void EndTake(params DiagField[] fields)
    {
        string? line = null;
        lock (sync) {
            if (current is { Ended: false } take) line = Close(take, fields);
        }
        if (line != null) Compact?.Invoke(line);
    }

    void Add(string name, DiagField[] fields, bool compact)
    {
        string? line = null;
        lock (sync) {
            if (current is { Ended: false } take) line = Append(take, name, fields, compact);
            else { string text = name + Fields(fields); AppLine(text); if (compact) line = "diag app +" + (clock() - appStartMs) + " ms " + text; }
        }
        if (compact && line != null) Compact?.Invoke(line);
    }

    string Close(Take take, IEnumerable<DiagField> fields)
    {
        var summary = new List<DiagField>(fields);
        foreach (var (name, count) in take.Counts) summary.Add(new(name, count));
        if (take.Dropped > 0) summary.Add(new("droppedLines", take.Dropped));
        string line = Append(take, "take.end", [.. summary], compact: true);
        take.Ended = true;
        return line;
    }

    /// Adds one line to `take` (under `sync`) and returns its compact form for insertion.log.
    string Append(Take take, string name, DiagField[] fields, bool compact, string? raw = null)
    {
        long elapsed = Math.Max(0, clock() - take.StartMs);
        if (name != "take.start" && name != "take.end" && name != "log") take.Counts[name] = take.Counts.GetValueOrDefault(name) + 1;
        string body = raw ?? Fields(fields);
        string line = "+" + elapsed.ToString(CultureInfo.InvariantCulture) + " ms " + name + (raw != null ? " " + raw : body);
        if (take.Lines.Count >= MaxEventsPerTake && name != "take.end") take.Dropped++;
        else { take.Lines.Add(line); take.Chars += line.Length; chars += line.Length; }
        while (chars > MaxChars && takes.Count > 1 && takes.First!.Value != take) Forget(takes.First.Value);
        return compact ? "diag take " + take.Number + " " + line : line;
    }

    void Forget(Take take) { chars -= take.Chars; takes.Remove(take); }

    void AppLine(string text)
    {
        string line = "+" + (clock() - appStartMs).ToString(CultureInfo.InvariantCulture) + " ms " + text;
        app.AddLast(line); chars += line.Length;
        while (app.Count > MaxAppEvents) { chars -= app.First!.Value.Length; app.RemoveFirst(); }
    }

    static string Fields(DiagField[] fields)
    {
        if (fields.Length == 0) return "";
        var text = new StringBuilder();
        foreach (var field in fields) text.Append(' ').Append(Key(field.Key)).Append('=').Append(Value(field.Value));
        return text.ToString();
    }

    static string Key(string key) => new(key.Where(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-').Take(40).ToArray());

    /// A value as the report shows it: invariant numbers, yes/no, and text with paths replaced,
    /// control characters as spaces, cut to `limit` characters.
    public static string Value(object? value, int limit = MaxValueLength)
    {
        string text = value switch {
            null => "-",
            bool flag => flag ? "yes" : "no",
            double number => double.IsFinite(number) ? Math.Round(number, 1).ToString(CultureInfo.InvariantCulture) : "-",
            float number => float.IsFinite(number) ? Math.Round(number, 1).ToString(CultureInfo.InvariantCulture) : "-",
            IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
            _ => value.ToString() ?? "-"
        };
        text = PrivateLog.Scrub(text);
        var clean = new StringBuilder(Math.Min(text.Length, limit + 1));
        foreach (char c in text) {
            if (clean.Length >= limit) { clean.Append('…'); break; }
            clean.Append(char.IsControl(c) ? ' ' : c);
        }
        string result = clean.ToString().Trim();
        return result.Length == 0 ? "-" : result.Contains(' ') && value is string ? "\"" + result.Replace("\"", "'") + "\"" : result;
    }

    /// How many words a text has, for a field that must not carry the text itself.
    public static int Words(string? text) => string.IsNullOrWhiteSpace(text) ? 0 : text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// The whole report: `environment` (gathered when the report is saved), pFlow's app events, then
    /// each kept take, oldest first.
    public string Report(IEnumerable<DiagField> environment, string title = "pFlow diagnostic report")
    {
        var text = new StringBuilder();
        text.AppendLine(title);
        text.AppendLine("Saved " + now().ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture) + ". It holds no dictated words, window titles, clipboard contents or file paths.");
        text.AppendLine();
        text.AppendLine("[environment]");
        foreach (var field in environment) text.Append(Key(field.Key)).Append(": ").AppendLine(Value(field.Value, 160));
        lock (sync) {
            text.AppendLine();
            text.AppendLine("[pFlow, ms since it started]");
            foreach (string line in app) text.AppendLine(line);
            foreach (var take in takes) {
                text.AppendLine();
                text.AppendLine("[take " + take.Number + ", began " + take.Started.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + ", ms since it began]");
                foreach (string line in take.Lines) text.AppendLine(line);
                if (!take.Ended) text.AppendLine("(take still open)");
                if (take.Dropped > 0) text.AppendLine("(" + take.Dropped + " more lines not kept)");
            }
        }
        return text.ToString();
    }

    public int TakeCount { get { lock (sync) return takes.Count; } }
    public long Chars { get { lock (sync) return chars; } }
}

/// The app's one recorder. Tests put in their own.
public static class Diagnostics
{
    public static DiagnosticRecorder Recorder { get; set; } = new();
}
