using System.Text.Json;
using System.Text.Json.Serialization;

namespace PFlow.Core;

public enum Phase { Idle, Recording, Continuous, Processing, Inserting, Inserted, Canceled, Failed, Saved }
public sealed class DictionaryEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Heard { get; set; } = "";
    public string Replacement { get; set; } = "";
}
public sealed class ReportSection
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Instructions { get; set; } = "";
    public bool Bullets { get; set; }
    public bool Summarize { get; set; }
    public bool? IncludeFullDictation { get; set; }
}
public sealed class DictationTemplate
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Title { get; set; } = "";
    public string Instructions { get; set; } = "";
    public string HeadingStyle { get; set; } = "plain";
    public bool? BoldHeadings { get; set; }
    public string MissingText { get; set; } = "Not provided.";
    public List<ReportSection> Sections { get; set; } = [];
    public List<string>? VoiceTriggers { get; set; }
    public bool NeedsAI => Sections.Any(s => s.IncludeFullDictation != true);
    // Migration/reference fixtures only. New users start with an empty template catalog.
    public static List<DictationTemplate> LegacyExamples() => new[] { "Police report", "Supplement", "Follow-up report" }.Select((name, index) => new DictationTemplate {
        Name = name, Title = index == 0 ? "Incident report" : index == 1 ? "Supplemental report" : name,
        Instructions = "Write a factual report. Preserve the speaker's perspective. Do not infer facts or include advice.",
        VoiceTriggers = index == 0 ? ["initial report", "police report"] : index == 1 ? ["supplement", "supplemental report"] : ["follow up", "follow-up report"],
        Sections = [new() { Title = "Narrated by" }, new() { Title = "Synopsis", Summarize = true }, new() { Title = "Date and time" }, new() { Title = "Narrative", IncludeFullDictation = true }, new() { Title = "Evidence", Bullets = true }]
    }).ToList();
    public static bool IsUnchangedExample(DictationTemplate? value) => value != null && LegacyExamples().Any(example =>
        value.Name == example.Name && value.Title == example.Title && value.Instructions == example.Instructions &&
        value.HeadingStyle == example.HeadingStyle && value.BoldHeadings == example.BoldHeadings && value.MissingText == example.MissingText &&
        value.VoiceTriggers != null && value.VoiceTriggers.SequenceEqual(example.VoiceTriggers!) && value.Sections != null && value.Sections.Count == example.Sections.Count &&
        value.Sections.Zip(example.Sections).All(pair => pair.First != null && pair.First.Title == pair.Second.Title && pair.First.Instructions == pair.Second.Instructions &&
            pair.First.Bullets == pair.Second.Bullets && pair.First.Summarize == pair.Second.Summarize && pair.First.IncludeFullDictation == pair.Second.IncludeFullDictation));

}
public sealed class Preferences
{
    public bool Enabled { get; set; } = true;
    public bool CopyDictationToClipboard { get; set; }
    public bool Sounds { get; set; } = true;
    public bool Paragraphs { get; set; } = true;
    public bool UseLocalAI { get; set; } = true;
    public bool Cleanup { get; set; } = true;
    public bool UseAICleanup { get; set; }
    public string Theme { get; set; } = "dark";
    public string Palette { get; set; } = "pesh";
    public string Accent { get; set; } = "FF9DC4";
    public string? CustomAccent { get; set; }
    public string WaveBlend { get; set; } = "3DFF85";
    public string Waveform { get; set; } = "wave";
    public string Language { get; set; } = "en";
    public int CapsulePositionVersion { get; set; }
    public double CapsuleX { get; set; } = -1;
    public double CapsuleY { get; set; } = -1;
    public List<string> DictionaryTerms { get; set; } = [];
    public List<DictionaryEntry> DictionaryReplacements { get; set; } = [];
    public List<DictationTemplate> Templates { get; set; } = [];
    public int TemplateCatalogVersion { get; set; }
    public Guid? ActiveTemplateId { get; set; }
    public void Validate()
    {
        if (Theme is not ("dark" or "light" or "system")) Theme = "dark";
        if (Palette is not ("pesh" or "aurora" or "solar" or "custom")) Palette = "pesh";
        if (Waveform is not ("wave" or "lines")) Waveform = "wave";
        if (!System.Text.RegularExpressions.Regex.IsMatch(Accent ?? "", "^[0-9a-fA-F]{6}$")) Accent = "FF9DC4";
        CustomAccent ??= Palette == "custom" ? Accent : "FF9DC4";
        if (!System.Text.RegularExpressions.Regex.IsMatch(CustomAccent ?? "", "^[0-9a-fA-F]{6}$")) CustomAccent = "FF9DC4";
        if (!System.Text.RegularExpressions.Regex.IsMatch(WaveBlend ?? "", "^[0-9a-fA-F]{6}$")) WaveBlend = "3DFF85";
        if (!double.IsFinite(CapsuleX) || !double.IsFinite(CapsuleY)) { CapsuleX = CapsuleY = -1; CapsulePositionVersion = 0; }
        DictionaryTerms ??= []; DictionaryReplacements ??= []; Templates ??= [];
        if (TemplateCatalogVersion < 1) {
            var removed = Templates.Where(DictationTemplate.IsUnchangedExample).Select(template => template.Id).ToHashSet();
            Templates.RemoveAll(template => DictationTemplate.IsUnchangedExample(template));
            if (ActiveTemplateId.HasValue && removed.Contains(ActiveTemplateId.Value) && !Templates.Any(template => template?.Id == ActiveTemplateId)) ActiveTemplateId = null;
            TemplateCatalogVersion = 1;
        }
        Language = string.IsNullOrWhiteSpace(Language) || Language.Equals("auto", StringComparison.OrdinalIgnoreCase) ? "en" : Language.Trim().ToLowerInvariant();
    }
}
public sealed record Transcript(Guid Id, string Text, DateTimeOffset CreatedAt, double? DurationSeconds,
    string? InputDeviceName, int? SpokenWordCount, string? ApplicationName, string? ApplicationBundleID, string InsertionStatus);
public sealed record Usage(int Dictations, int Words, double Seconds)
{
    public int TimedWords { get; init; }
    public double WordsPerMinute { get; init; }
    public static Usage From(IEnumerable<Transcript> records)
    {
        var all = records.ToList(); var timed = all.Where(x => x.DurationSeconds > 0 && double.IsFinite(x.DurationSeconds.Value) && x.SpokenWordCount >= 0).ToList();
        var seconds = timed.Sum(x => x.DurationSeconds!.Value);
        return new(all.Count, all.Sum(x => x.SpokenWordCount ?? TextProcessing.WordCount(x.Text)), seconds) {
            TimedWords = timed.Sum(x => x.SpokenWordCount!.Value),
            WordsPerMinute = seconds > 0 ? timed.Sum(x => x.SpokenWordCount!.Value) * 60.0 / seconds : 0 };
    }
}
public sealed class StateStore
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public string DirectoryPath { get; }
    public Preferences Preferences { get; private set; }
    public List<Transcript> History { get; private set; }
    public StateStore(string directory)
    {
        DirectoryPath = directory; Directory.CreateDirectory(directory);
        Preferences = Read<Preferences>("settings.json") ?? new(); bool migrate = Preferences.TemplateCatalogVersion < 1; Preferences.Validate();
        History = Read<List<Transcript>>("history.json") ?? [];
        if (migrate) {
            string settings = Path.Combine(directory, "settings.json"), backup = Path.Combine(directory, "settings-before-custom-templates.json");
            if (File.Exists(settings) && !File.Exists(backup)) File.Copy(settings, backup);
            SavePreferences();
        }
    }
    T? Read<T>(string name)
    {
        var path = Path.Combine(DirectoryPath, name);
        if (!File.Exists(path)) return default;
        // Never silently replace corrupt owner data with defaults.
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) ?? throw new InvalidDataException($"Could not read {name}. Your file was kept.");
    }
    public void Write(string name, object value)
    {
        var path = Path.Combine(DirectoryPath, name); var temp = path + ".new";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Json));
        File.Move(temp, path, true);
    }
    public void SavePreferences() { Preferences.Validate(); Write("settings.json", Preferences); }
    public void Add(Transcript transcript) { History.Insert(0, transcript); Write("history.json", History); }
    public void Delete(Guid id) { History.RemoveAll(x => x.Id == id); Write("history.json", History); }
}
