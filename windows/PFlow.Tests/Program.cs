using PFlow.Core;
using System.Text.Json;
using System.Text.RegularExpressions;

if (args.Contains("--updates-network-only")) { await UpdateChecks.Network(); return; }
if (args.Contains("--capture-only")) { KeyCaptureChecks.Run(); return; }
if (args.Contains("--learn-keys-only")) { HotkeyChecks.Run(); KeyCaptureChecks.Run(); return; }
if (args.Contains("--live-text-only")) { await LiveTextChecks.Run(); LiveInlineChecks.Run(); SpeechChecks.Run(); InstalledChecks.Run(); return; }
if (args.Contains("--installed-only")) { InstalledChecks.Run(); return; }
UpdateChecks.Run();
if (!args.Contains("--hotkeys-only")) await UpdateChecks.Network();
if (args.Contains("--updates-only")) return;
HotkeyChecks.Run();
KeyCaptureChecks.Run();
if (args.Contains("--hotkeys-only")) return;
await LiveTextChecks.Run();
LiveInlineChecks.Run();
SpeechChecks.Run();
InstalledChecks.Run();
int passed = 0;
void Check(string name, bool condition) { if (!condition) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
string Words(string value) => string.Join(" ", Regex.Split(value.Trim(), @"\s+"));
DictionaryEntry Rule(string heard, string replacement) => new() { Heard = heard, Replacement = replacement };

void StatisticsChecks()
{
    var today = new DateOnly(2026, 11, 3);
    Transcript Item(DateOnly day, string text, int? words, double? seconds, string? name, string? id, int hour = 12) =>
        new(Guid.NewGuid(), text, new DateTimeOffset(day.ToDateTime(new TimeOnly(hour, 0), DateTimeKind.Local)), seconds, null, words, name, id, "Inserted");
    var rows = new List<Transcript> {
        Item(today, "Fictional timed one", 120, 60, "Notepad", "notepad", 13), Item(today, "Fictional timed two", 60, 120, "Former name", "notepad"),
        Item(today, "Legacy words", null, null, null, null), Item(today.AddDays(-1), "Fictional Edge", 30, 15, "Edge", "msedge"),
        Item(today.AddDays(-40), "Legacy archive", 9, null, " ", " ") };
    var stats = UsageStatistics.From(rows, today);
    Check("statistics totals include legacy words", stats.Total.Dictations == 5 && stats.Total.Words == 221);
    Check("pace weights recorded words and time, excluding legacy", stats.Total.TimedWords == 210 && stats.Total.Seconds == 195 && Math.Abs(stats.Total.WordsPerMinute - 210.0 * 60 / 195) < .0001);
    Check("seven local calendar dates are oldest first including today", stats.RecentDays.Select(x => x.Date).SequenceEqual(Enumerable.Range(-6, 7).Select(today.AddDays)));
    Check("quiet dates are zero filled", stats.RecentDays.Take(5).All(x => x.Totals.Words == 0 && x.Totals.Dictations == 0));
    Check("chart and daily table agree on words", stats.RecentDays[^1].Totals.Words == 182 && stats.ActiveDays[0].Totals == stats.RecentDays[^1].Totals);
    Check("day table includes old active days newest first", stats.ActiveDays.Select(x => x.Date).SequenceEqual(new[] { today, today.AddDays(-1), today.AddDays(-40) }));
    Check("apps group stable IDs despite name changes", stats.Applications.Count == 3 && stats.Applications[0].Name == "Notepad" && stats.Applications[0].Totals.Words == 180);
    Check("apps rank by word count, not dictation count", stats.Applications.Select(x => x.Totals.Words).SequenceEqual(new[] { 180, 30, 11 }));
    Check("missing app metadata has a readable legacy label", stats.Applications[^1].Name == "Earlier activity" && stats.Applications[^1].Totals.Seconds == 0);
    Check("missing timing is never borrowed from legacy words", Usage.From([rows[2], rows[4]]).TimedWords == 0 && Usage.From([rows[2], rows[4]]).WordsPerMinute == 0);
    var invalid = new[] { double.NaN, double.PositiveInfinity, -1, 0 }.Select(x => Item(today, "Invalid timing", 10, x, "Fixture", "fixture"));
    Check("invalid timing cannot poison totals", Usage.From(invalid).Seconds == 0 && Usage.From(invalid).TimedWords == 0);
    var old = Enumerable.Range(0, 40).Select(x => Item(today.AddDays(-x), "Archive", 1, null, "Fixture", "fixture")).ToList();
    Check("daily table shows the most recent 30 active dates", UsageStatistics.From(old, today).ActiveDays.Select(x => x.Date).SequenceEqual(Enumerable.Range(0, 30).Select(x => today.AddDays(-x))));
    Check("all time apps retain older than 30 day counts", UsageStatistics.From(old, today).Applications.Single().Totals.Words == 40);
    // Exercise the DST transition using the actual local offset of each calendar day.
    var dst = UsageStatistics.From(new[] { new DateOnly(2026, 11, 1), new DateOnly(2026, 3, 8) }.Select(d => Item(d, "Boundary", 1, 1, "Fixture", "fixture")), today);
    Check("DST transition recordings retain their local calendar dates", dst.ActiveDays.Select(x => x.Date).SequenceEqual(new[] { new DateOnly(2026, 11, 1), new DateOnly(2026, 3, 8) }));
    var midnight = new DateTimeOffset(today.ToDateTime(new TimeOnly(0, 15), DateTimeKind.Local));
    Check("offset timestamps group by this PC local date", UsageStatistics.From([rows[0] with { CreatedAt = midnight.ToOffset(TimeSpan.FromHours(12)) }], today).ActiveDays.Single().Date == today);
    var empty = UsageStatistics.From([], today);
    Check("empty history has seven quiet dates without fake timing", empty.Total.Words == 0 && empty.Total.Seconds == 0 && empty.RecentDays.Count == 7 && empty.ActiveDays.Count == 0 && empty.Applications.Count == 0);
    var named = UsageStatistics.From([Item(today, "A", 1, 1, "同名", "one"), Item(today, "B", 1, 1, "同名", "two"), Item(today, "C", 1, 1, "Name only", null)], today);
    Check("distinct IDs remain separate with Unicode names", named.Applications.Count == 3 && named.Applications.Count(x => x.Name == "同名") == 2);
    Check("statistics snapshot leaves history intact", rows.Count == 5 && rows[0].Text == "Fictional timed one" && rows[2].DurationSeconds == null);
}
StatisticsChecks();
if (args.Contains("--statistics-only")) { Console.WriteLine($"{passed} statistics checks passed."); return; }

void TemplateCatalogChecks()
{
    Check("fresh users have no example templates", new Preferences().Templates.Count == 0);
    string directory = Path.Combine(Path.GetTempPath(), "pflow-templates-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
    try {
        var examples = DictationTemplate.LegacyExamples();
        var custom = new DictationTemplate { Name = "Bicycle inspection", Sections = [new() { Title = "Inspection notes", IncludeFullDictation = true }] };
        var legacy = new Preferences { Templates = [.. examples, custom], ActiveTemplateId = examples[1].Id, Palette = "aurora", DictionaryTerms = ["Fictional Morgan"] };
        string original = JsonSerializer.Serialize(legacy, StateStore.Json);
        File.WriteAllText(Path.Combine(directory, "settings.json"), original);
        File.WriteAllText(Path.Combine(directory, "history.json"), "[]");
        var store = new StateStore(directory);
        Check("only unchanged examples removed on existing upgrade", store.Preferences.Templates.Select(t => t.Id).SequenceEqual(new[] { custom.Id }));
        Check("removed active example returns to plain dictation", store.Preferences.ActiveTemplateId == null);
        Check("unrelated saved preferences remain intact", store.Preferences.Palette == "aurora" && store.Preferences.DictionaryTerms.SequenceEqual(legacy.DictionaryTerms));
        Check("raw original settings backed up before upgrade", File.ReadAllText(Path.Combine(directory, "settings-before-custom-templates.json")) == original);
        Check("upgrade persists an empty-default catalog version", new StateStore(directory).Preferences.TemplateCatalogVersion == 1);
        Check("custom template survives reopening", new StateStore(directory).Preferences.Templates.Single().Name == custom.Name);
        foreach (var edit in new Action<DictationTemplate>[] {
            t => t.Name += " edited", t => t.Title += " edited", t => t.Instructions += " edited", t => t.HeadingStyle = "bold", t => t.BoldHeadings = false,
            t => t.MissingText = "Unknown", t => t.VoiceTriggers!.Add("custom trigger"), t => t.Sections[0].Title = "My heading", t => t.Sections[0].Instructions = "My rules",
            t => t.Sections[0].Bullets = true, t => t.Sections[0].Summarize = true, t => t.Sections[0].IncludeFullDictation = false }) {
            var modified = DictationTemplate.LegacyExamples()[0]; edit(modified);
            var preferences = new Preferences { Templates = [modified], ActiveTemplateId = modified.Id }; preferences.Validate();
            Check("edited example and its selection are preserved", preferences.Templates.Single().Id == modified.Id && preferences.ActiveTemplateId == modified.Id);
        }
        var namedLikeExample = new DictationTemplate { Name = "Police report", Sections = [new() { Title = "My notes", IncludeFullDictation = true }] };
        var activeCustom = new Preferences { Templates = [.. DictationTemplate.LegacyExamples(), namedLikeExample], ActiveTemplateId = namedLikeExample.Id }; activeCustom.Validate();
        Check("name matching alone never removes a user's template", activeCustom.Templates.Single().Id == namedLikeExample.Id && activeCustom.ActiveTemplateId == namedLikeExample.Id);
        store.Preferences.Templates.Add(DictationTemplate.LegacyExamples()[0]); store.SavePreferences();
        Check("migration runs once and preserves later user imports", new StateStore(directory).Preferences.Templates.Count == 2);
        Check("reopening never overwrites the settings backup", File.ReadAllText(Path.Combine(directory, "settings-before-custom-templates.json")) == original);
        var clean = new StateStore(Path.Combine(directory, "new-user"));
        Check("new installed user starts with plain dictation and no catalog", clean.Preferences.Templates.Count == 0 && clean.Preferences.ActiveTemplateId == null);
    } finally { Directory.Delete(directory, true); }
}
TemplateCatalogChecks();
if (args.Contains("--template-catalog-only")) { Console.WriteLine($"{passed} template catalog checks passed."); return; }

void CapsuleSpacingChecks()
{
    string Pad(string text, string value, int? start = null, int length = 0) => InsertionSpacing.AtCaret(text, value, start ?? value.Length, length).Apply(text);
    foreach (var (value, incoming, expected) in new[] {
        ("First sentence.", "Next sentence.", " Next sentence."), ("First. ", "Next.", "Next."), ("First.\n\n", "Next.", "Next."), ("", "First.", "First."),
        ("Start", ", then stop.", ", then stop."), ("ID-", "2026", "2026"), ("(", "name", "name"), ("👮🏽‍♀️ Café.", "Next.", " Next."),
        ("第一句。", "下一句。", "下一句。"), ("こんにちは。", "こんにちは。", "こんにちは。"), ("First.", " Next.", " Next."), ("First.", "\n\nNext.", "\n\nNext.") })
        Check("destination spacing: " + value, Pad(incoming, value) == expected);
    Check("selected replacement unchanged", Pad("Sinton", "staff", 0, 5) == "Sinton");
    Check("within-word insertion unchanged", Pad("t", "Sinon", 3) == "t");
    Check("within-combining-character insertion unchanged", Pad("x", "e\u0301", 1) == "x");
    Check("invalid emoji caret unchanged", Pad("Test", "👋", 1) == "Test");
    Check("right boundary gets one space", Pad("new", "A word", 2) == "new ");
    string field = "First sentence.";
    foreach (string next in new[] { "Second sentence.", "Third sentence." }) field = new FieldState(1, 1, "fictional", field, field.Length, 0).Inserted(Pad(next, field));
    Check("successive insertions separate sentences", field == "First sentence. Second sentence. Third sentence.");
    Check("recognition pause segments have separators", TextProcessing.JoinRecognitionLines("First.\nSecond.\r\nThird.") == "First. Second. Third.");
    Check("recognition blank paragraphs preserved", TextProcessing.JoinRecognitionLines("First.\n\nNext.") == "First.\n\nNext.");
    Check("recognition lists preserved", TextProcessing.JoinRecognitionLines("1. First.\n2. Next.") == "1. First.\n2. Next.");
    // Whisper segment lines start with a space; the owner saw "this  brown" and "sea  of pee" at every join.
    Check("segment joins never double a space", TextProcessing.JoinRecognitionLines("there was this\n brown little fox\n and he stunk\n like all sin.") == "there was this brown little fox and he stunk like all sin.");
    Check("segment joins keep paragraph breaks and collapse tabs", TextProcessing.JoinRecognitionLines("First part. \n\n Second\tpart.\n continues.") == "First part.\n\nSecond part. continues.");

    string sentence = "Morgan checked the blue bicycle near the front gate and recorded every visible detail in the fictional exercise. ";
    string account = string.Concat(Enumerable.Repeat(sentence, 4)) + "Regarding the witness, Alex described the silver lock and did not guess who left it there. " + string.Concat(Enumerable.Repeat(sentence, 4));
    string grouped = TextProcessing.Paragraphs(account);
    Check("paragraphs keep exact words", Words(grouped) == Words(account));
    Check("paragraphs group related sentences", grouped.Contains("\n\nRegarding the witness") && grouped.Split("\n\n").All(x => Regex.Matches(x, @"[.!?](?:\s|$)").Count >= 2));
    Check("pause segments format like continuous narration", TextProcessing.Paragraphs(TextProcessing.JoinRecognitionLines(account.Replace(". ", ".\n"))) == grouped);
    Check("explicit paragraphs preserved", TextProcessing.Paragraphs("First.\n\nNext.") == "First.\n\nNext.");
    var wave = new WaveMotion(); wave.Advance(1, .016); double attack = wave.Level; wave.Advance(0, .016);
    Check("meter attack and release are gradual", attack > 0 && attack < 1 && wave.Level > 0 && wave.Level < attack);
    var single = new WaveMotion(); single.Advance(.5, .16); var frames = new WaveMotion(); for (int i = 0; i < 10; i++) frames.Advance(.5, .016);
    Check("meter is independent of display cadence", single.Levels().Zip(frames.Levels()).All(pair => Math.Abs(pair.First - pair.Second) < 1e-8));
    wave.Reset(); wave.Advance(double.NaN, .1); Check("silence and invalid input stay flat", wave.Levels().All(x => x == 0));
    for(int i = 0; i < 100; i++) wave.Advance(1, .016); Check("loud levels bounded", wave.Levels().All(x => x >= 0 && x <= 1));
    // Waveform loudness: a fixture trace of a Windows microphone at ordinary speech levels must move the bars.
    Check("ordinary speech on a Windows microphone (-35 dBFS) rises above the capsule's 0.25 peak floor, so syllables fill the bars",
        AudioLevels.FromDecibels(-35) > 0.25 && AudioLevels.FromDecibels(-25) > 0.45 && AudioLevels.FromDecibels(-15) > 0.6);
    Check("room noise stays flat and the level is monotonic and bounded", AudioLevels.FromDecibels(-60) == 0 && AudioLevels.FromDecibels(-52) < 0.06 && AudioLevels.FromRms(0) == 0 && AudioLevels.FromRms(1) == 1 && AudioLevels.FromRms(2) == 1
        && AudioLevels.FromDecibels(-40) < AudioLevels.FromDecibels(-30) && AudioLevels.FromDecibels(-30) < AudioLevels.FromDecibels(-20));
    { var trace = new WaveMotion(); double peak = 0; var speech = new[] { -50, -38, -32, -28, -30, -36, -48, -50, -31, -27, -33, -47 };
      foreach (int db in speech) { for (int i = 0; i < 6; i++) trace.Advance(AudioLevels.FromDecibels(db), .016); peak = Math.Max(peak, trace.Levels().Max()); }
      Check("a speech-shaped trace at normal microphone levels peaks above 0.4 of full scale (was 0.2 with the old -45 dB floor)", peak > 0.4); }
    Check("same words: line breaks and spaces may differ, words may not", TextProcessing.SameWords("one two\n\nthree", "one  two three") && !TextProcessing.SameWords("one two", "onetwo") && !TextProcessing.SameWords("one two", "one two three") && TextProcessing.SameWords(" a ", "a"));
    Check("log lines lose every path, so an account name never reaches the log", PrivateLog.Scrub(@"Could not find file 'C:\Users\Fictional\AppData\Local\pFlow\x.json'.") == "Could not find file '<path>'."
        && PrivateLog.Scrub(@"\\server\share\Fictional\f.txt was locked") == "<path> was locked" && PrivateLog.Scrub("/Users/fictional/Library/x failed") == "<path> failed"
        && PrivateLog.Scrub("Focus changed. Your text is in History.") == "Focus changed. Your text is in History." && PrivateLog.Reason(new IOException(@"locked D:\Fictional\a.b")) == "IOException: locked <path>");
    Check("a path with a space in the account name is scrubbed whole, quoted or not",
        PrivateLog.Scrub(@"Could not find file 'C:\Users\John Smith\AppData\Local\pFlow\x.json'.") == "Could not find file '<path>'."
        && PrivateLog.Scrub(@"Access to C:\Users\John Smith\Documents\notes.txt was denied") == "Access to <path> was denied"
        && PrivateLog.Scrub(@"Access to the path 'C:\Users\John Smith' is denied.") == "Access to the path '<path>' is denied."
        && PrivateLog.Scrub("open \"/Users/John Smith/Library/x\" failed") == "open \"<path>\" failed"
        && PrivateLog.Scrub("/home/john smith/a b/x failed") == "<path> failed"
        && !PrivateLog.Scrub(@"saved C:\Users\John Smith\Desktop\a.txt and D:\Users\Jane Smith\b.txt").Contains("Smith"));
    // Setup carries the package at its end, found only through the trailer.
    { var trailer = SetupPackage.Trailer(123456); var bytes = new byte[500000];
      Check("the setup trailer names where the ZIP starts", trailer.Length == 16 && SetupPackage.ZipStart(trailer, 500000) == 123456);
      Check("no trailer, a wrong magic, or an offset past the end means no package", SetupPackage.ZipStart(new byte[16], 500000) == null && SetupPackage.ZipStart(trailer, 100) == null && SetupPackage.ZipStart(trailer[..15], 500000) == null);
      Check("package paths stay under the unpack folder", SetupPackage.SafeEntry("payloads/win-x64/pFlow.exe") && SetupPackage.SafeEntry("shared/models/") && !SetupPackage.SafeEntry("../x") && !SetupPackage.SafeEntry("a/../b") && !SetupPackage.SafeEntry("/etc") && !SetupPackage.SafeEntry("C:\\x") && !SetupPackage.SafeEntry("")); }
    var areas = new[] { new WorkArea(0, 0, 1920, 1040), new WorkArea(-1920, 0, 1920, 1040) };
    Check("default bottom center", CapsulePlacement.Place(areas, 0, 120, 32, null, null) == (900, 968));
    Check("focused negative display bottom center", CapsulePlacement.Place(areas, 1, 120, 32, null, null) == (-1020, 968));
    Check("user position restored", CapsulePlacement.Place(areas, 0, 120, 32, -1500, 200) == (-1500, 200));
    Check("lost display recenters", CapsulePlacement.Place(areas, 0, 120, 32, 5000, 5000) == (900, 968));
    Check("saved edge position stays within work area", CapsulePlacement.Place(areas, 0, 120, 32, 1880, 1020) == (1800, 1008));
    Check("high DPI bottom margin scales", CapsulePlacement.Place([new WorkArea(0, 0, 3840, 2080)], 0, 240, 64, null, null) == (1800, 1936));
}
CapsuleSpacingChecks();
if (args.Contains("--capsule-spacing-only")) { Console.WriteLine($"{passed} capsule and spacing checks passed."); return; }

void AppearancePreferenceChecks()
{
    var old = new Preferences { Palette = "custom", Accent = "336699" }; old.Validate();
    Check("legacy custom accent migrates", old.CustomAccent == "336699" && old.WaveBlend == "3DFF85");
    var invalid = new Preferences { Palette = "unknown", CustomAccent = "bad", WaveBlend = "no" }; invalid.Validate();
    Check("invalid colors use safe defaults", invalid.Palette == "pesh" && invalid.CustomAccent == "FF9DC4" && invalid.WaveBlend == "3DFF85");
    string directory = Path.Combine(Path.GetTempPath(), "pflow-colors-" + Guid.NewGuid());
    try {
        var store = new StateStore(directory); store.Preferences.CustomAccent = "F587B5"; store.Preferences.WaveBlend = "4EE5B3"; store.Preferences.Palette = "solar"; store.Preferences.Accent = "FFBB66"; store.SavePreferences();
        var loaded = new StateStore(directory).Preferences;
        Check("custom colors persist apart from selected palette", loaded.Palette == "solar" && loaded.CustomAccent == "F587B5" && loaded.WaveBlend == "4EE5B3");
    } finally { Directory.Delete(directory, true); }
}
AppearancePreferenceChecks();
if (args.Contains("--appearance-preferences-only")) { Console.WriteLine($"{passed} appearance preference checks passed."); return; }

void CleanupLanguageChecks()
{
    foreach (var (language, source) in new[] { ("de", "Es geht um Morgan."), ("pt", "Vi um carro."), ("es", "Um llamó a Morgan."), ("fr", "Um appelle Morgan."), ("ja", "Um は Morgan に電話した。"), ("unknown", "Um, Morgan called.") }) {
        Check("other language retains exact words: " + language, TextProcessing.RemoveFillers(source, [], language) == source);
        Check("English AI rules disabled: " + language, !TextProcessing.SupportsEnglishCleanup(language));
    }
    foreach (string language in new[] { "en", "EN", "english" }) {
        Check("English preset removes filler: " + language, TextProcessing.RemoveFillers("Um, Morgan called.", [], language) == "Morgan called.");
        Check("English AI rules enabled: " + language, TextProcessing.SupportsEnglishCleanup(language));
    }
}
CleanupLanguageChecks();
if (args.Contains("--cleanup-language-only")) { Console.WriteLine($"{passed} language cleanup checks passed."); return; }

void FastCleanupChecks()
{
Check("filler removal matches Mac basics", TextProcessing.RemoveFillers("Um, Morgan, uh, checked the blue bicycle.", []) == "Morgan, checked the blue bicycle.");
Check("filler-free wording stays exact", TextProcessing.RemoveFillers("human summary.  eBay stays.", []) == "human summary.  eBay stays.");
Check("brand case survives leading filler", TextProcessing.RemoveFillers("Um, eBay called Morgan.", []) == "eBay called Morgan.");
Check("learned filler-like name survives", TextProcessing.RemoveFillers("Um called Morgan, uh.", ["Um"]) == "Um called Morgan.");
Check("learned multiword name survives", TextProcessing.RemoveFillers("Um called Morgan, uh.", ["Officer Um"]) == "Um called Morgan.");
Check("intentional repeats and negation survive", TextProcessing.RemoveFillers("Um, it was very very cold. No, not not available.", []) == "It was very very cold. No, not not available.");
Check("filler-only dictation is not erased", TextProcessing.RemoveFillers("Um.", []) == "Um.");
Check("paragraph delimiters survive", TextProcessing.RemoveFillers("Um, Morgan called.\r\n\r\nUh, Pesh answered.", []) == "Morgan called.\r\n\r\nPesh answered.");
foreach(var value in new[] { "Um, Morgan said \"five\".", "Um, at -12, Morgan called.", "Um, Morgan/Alex called 🙂.", "Um, Morgan didn't call." })
    Check("risky block remains exact: " + value, TextProcessing.RemoveFillers(value, []) == value);
var directory = Path.Combine(Path.GetTempPath(), "pflow-fast-" + Guid.NewGuid());
try {
 var store = new StateStore(directory);
 Check("new dictation uses English and immediate cleanup", store.Preferences.Language == "en" && store.Preferences.Cleanup && !store.Preferences.UseAICleanup);
 store.Preferences.UseAICleanup = true; store.Preferences.Language = "es"; store.SavePreferences();
 var loaded = new StateStore(directory);
 Check("explicit preset and AI choices persist", loaded.Preferences.UseAICleanup && loaded.Preferences.Language == "es");
 File.WriteAllText(Path.Combine(directory, "settings.json"), "{\"language\":\"auto\"}");
 Check("legacy auto becomes English preset", new StateStore(directory).Preferences.Language == "en");
} finally { Directory.Delete(directory, true); }
}
FastCleanupChecks();
if (args.Contains("--fast-cleanup-only")) { Console.WriteLine($"{passed} fast cleanup checks passed."); return; }

void FidelityChecks()
{
Check("cleanup permits stammer repair", TextFidelity.CleanupIsFaithful("The server server stopped. Pesh did not restart it.", "The server stopped. Pesh did not restart it."));
Check("cleanup rejects changed numbers", !TextFidelity.CleanupIsFaithful("Pesh arrived at 14:30.", "Pesh arrived at 14:31."));
Check("cleanup rejects lost negation", !TextFidelity.CleanupIsFaithful("Morgan did not collect evidence.", "Morgan collected evidence."));
Check("cleanup rejects lost names", !TextFidelity.CleanupIsFaithful("Officer Morgan spoke with Sinton.", "Officer Morgan spoke with Senten."));
Check("cleanup rejects changed perspective", !TextFidelity.CleanupIsFaithful("I spoke with Pesh.", "He spoke with Pesh."));
Check("cleanup preserves short names", !TextFidelity.CleanupIsFaithful("Jo met Li.", "Bo met Li."));
Check("cleanup rejects added hype", !TextFidelity.CleanupIsFaithful("Pesh checked the server.", "Pesh checked the amazing server."));
Check("cleanup preserves explicit paragraphs", !TextFidelity.CleanupIsFaithful("Pesh checked it.\n\nMorgan called.", "Pesh checked it. Morgan called."));
Check("cleanup rejects moved comparison with word numbers", !TextFidelity.CleanupIsFaithful("The result was < five, not ten.", "The result was five, not < ten."));
Check("cleanup rejects moved quotation", !TextFidelity.CleanupIsFaithful("Morgan said \"Alex hit Pesh\".", "\"Morgan said Alex\" hit Pesh."));
Check("cleanup rejects introduced operator", !TextFidelity.CleanupIsFaithful("Morgan saw Alex.", "Morgan < saw Alex."));
Check("cleanup rejects introduced quotes", !TextFidelity.CleanupIsFaithful("Morgan saw Alex.", "Morgan saw \"Alex\"."));
Check("cleanup keeps risky blocks exactly", TextFidelity.CleanupIsFaithful("At - 12, Morgan said \"five\" 🙂.", "At - 12, Morgan said \"five\" 🙂."));
Check("cleanup permits stammer repair beside an intact time", TextFidelity.CleanupIsFaithful("The server server stopped at 14:30.", "The server stopped at 14:30."));
Check("cleanup never collapses a repeated number", !TextFidelity.CleanupIsFaithful("Room five five, by the stairs 5 5.", "Room five five, by the stairs 5."));
// Numbers spoken as words are numbers: a repeat is a digit, never a stammer ("room five five" is room 55).
Check("cleanup never collapses a repeated number word", !TextFidelity.CleanupIsFaithful("room five five", "Room five."));
Check("cleanup never collapses a repeated number word before another", !TextFidelity.CleanupIsFaithful("two two seven", "Two seven."));
Check("cleanup never collapses oh inside a number run", !TextFidelity.CleanupIsFaithful("agent oh oh seven", "Agent oh seven."));
Check("cleanup still punctuates a repeated number word", TextFidelity.CleanupIsFaithful("room five five", "Room five, five."));
Check("cleanup still repairs oh oh outside a number", TextFidelity.CleanupIsFaithful("oh oh well we tried", "Oh well, we tried."));
Check("symbols-only difference is told apart from changed words", TextFidelity.OnlySymbolsDiffer("5,6,7", "5, 6, 7") && TextFidelity.OnlySymbolsDiffer("it cost $40", "It cost 40.")
    && !TextFidelity.OnlySymbolsDiffer("we didn't go", "We did not go.") && !TextFidelity.OnlySymbolsDiffer("room five five", "Room five."));
// The model now sees takes with numbers, contractions and symbols; punctuation and case may change, nothing else.
Check("cleanup accepts punctuation and case around numbers", TextFidelity.CleanupIsFaithful("so next year in 4040 bc jimmy dean was born in a sea of pee", "So next year in 4040 BC, Jimmy Dean was born in a sea of pee."));
Check("cleanup accepts a comma in far far away with a contraction", TextFidelity.CleanupIsFaithful("far far away we didn't stop at 4:30", "Far, far away, we didn't stop at 4:30."));
Check("cleanup accepts a period after a number at the end", TextFidelity.CleanupIsFaithful("the total was 40 then we left", "The total was 40. Then we left."));
Check("cleanup rejects a changed number beside punctuation", !TextFidelity.CleanupIsFaithful("call me at 4:30 tomorrow", "Call me at 4:31 tomorrow."));
Check("cleanup rejects a lost apostrophe", !TextFidelity.CleanupIsFaithful("we didn't go", "We did not go."));
Check("cleanup rejects a dropped currency sign", !TextFidelity.CleanupIsFaithful("it cost $40 at the store", "It cost 40 at the store."));
Check("cleanup rejects a thousands separator turned into words", !TextFidelity.CleanupIsFaithful("about 1,000 people came", "About 1 000 people came."));
Check("cleanup accepts a spoken clock time written with a colon", TextFidelity.CleanupIsFaithful("we met him at about 6 30 and left", "We met him at about 6:30 and left.") && TextFidelity.CleanupIsFaithful("the train at 12 05 was late", "The train at 12:05 was late."));
Check("cleanup rejects a colon after an hour past 24", !TextFidelity.CleanupIsFaithful("the code was 25 30 today", "The code was 25:30 today."));
Check("cleanup rejects a colon before a minute past 59", !TextFidelity.CleanupIsFaithful("we met at 6 60", "We met at 6:60."));
Check("cleanup rejects a colon before a one-digit minute", !TextFidelity.CleanupIsFaithful("we met at 6 5", "We met at 6:5."));
Check("cleanup rejects a colon that was not inserted between the two numbers", !TextFidelity.CleanupIsFaithful("we met at 6 30", "We met at: 6 30."));
Check("cleanup still rejects a thousands comma or a decimal point joined into the number", !TextFidelity.CleanupIsFaithful("about 1 000 people", "About 1,000 people.") && !TextFidelity.CleanupIsFaithful("it was 3 5 metres", "It was 3.5 metres."));
Check("cleanup keeps a decimal inside a number", TextFidelity.CleanupIsFaithful("dose was 3.5 mg then rest", "Dose was 3.5 mg. Then rest."));
Check("cleanup rejects a dropped percent", !TextFidelity.CleanupIsFaithful("maybe 40% done", "Maybe 40 done."));
Check("cleanup accepts filler removal with symbols present", TextFidelity.CleanupIsFaithful("um the price is $5 uh each", "The price is $5 each."));
Check("cleanup accepts a question mark", TextFidelity.CleanupIsFaithful("are you coming at 5", "Are you coming at 5?"));
Check("cleanup rejects sign loss", !TextFidelity.CleanupIsFaithful("Temperature was -12 degrees.", "Temperature was 12 degrees."));
Check("cleanup rejects positive sign loss", !TextFidelity.CleanupIsFaithful("The balance was +12.", "The balance was 12."));
Check("cleanup rejects changed decimal", !TextFidelity.CleanupIsFaithful("Dose was .5 liters.", "Dose was 5 liters."));
Check("cleanup preserves fraction separator", !TextFidelity.CleanupIsFaithful("Dose was 1/2 mg.", "Dose was 1 2 mg."));
Check("cleanup preserves spaced sign", !TextFidelity.CleanupIsFaithful("Temperature was - 12 degrees.", "Temperature was 12 degrees."));
Check("cleanup preserves comparison", !TextFidelity.CleanupIsFaithful("Dose was <5 mg.", "Dose was >5 mg."));
Check("cleanup preserves percent", !TextFidelity.CleanupIsFaithful("Reading was 5%.", "Reading was 5."));
Check("cleanup preserves Unicode signs", !TextFidelity.CleanupIsFaithful("Value was − 5.", "Value was 5."));
Check("cleanup preserves range", !TextFidelity.CleanupIsFaithful("Range was 1–2.", "Range was 1 2."));
Check("cleanup preserves decimal symbol", !TextFidelity.CleanupIsFaithful("Value was 1.2.", "Value was 1,2."));
Check("cleanup preserves emoji", !TextFidelity.CleanupIsFaithful("Morgan called 🙂.", "Morgan called."));
Check("cleanup preserves nonnumeric symbols", !TextFidelity.CleanupIsFaithful("Call Morgan/Alex 🙂.", "Call Morgan Alex."));
Check("cleanup rejects subject swap", !TextFidelity.CleanupIsFaithful("Morgan hit Alex.", "Alex hit Morgan."));
Check("cleanup rejects moved negation", !TextFidelity.CleanupIsFaithful("Morgan did not hit Alex but called Pesh.", "Morgan did hit Alex but not called Pesh."));
Check("cleanup rejects added repeat", !TextFidelity.CleanupIsFaithful("Morgan saw Alex.", "Morgan saw saw Alex."));
Check("cleanup preserves repeated negation", !TextFidelity.CleanupIsFaithful("It was not not available.", "It was not available."));
Check("cleanup permits punctuation and filler removal", TextFidelity.CleanupIsFaithful("um morgan saw alex", "Morgan saw Alex."));
}
FidelityChecks();
if (args.Contains("--fidelity-only")) { Console.WriteLine($"{passed} fidelity checks passed."); return; }

// Fixtures ported from the MIT Mac ExactReplacementTests and DictationParagraphTests.
Check("whole words and whitespace", TextProcessing.Replace("SENTEN said sent  in. Sentences and Sentenland stay.", [Rule("Senten", "Sinton"), Rule("sent in", "Sinton")]) == "Sinton said Sinton. Sentences and Sentenland stay.");
Check("longest match no cascading", TextProcessing.Replace("sent in, then sent.", [Rule("sent", "mailed"), Rule("sent in", "Sinton"), Rule("Sinton", "Other")]) == "Sinton, then mailed.");
Check("literal replacement and Unicode", TextProcessing.Replace("C++ and éSenten and Senten's.", [Rule("C++", "$1\\SDK"), Rule("Senten", "Sinton")]) == "$1\\SDK and éSenten and Sinton's.");
Check("blank rule ignored", TextProcessing.Replace("keep me", [Rule(" ", "oops")]) == "keep me");
string arrival = "At 14:30, Officer Morgan Lee arrived at 12 Maple Street for a fictional training exercise. The front gate was open, and a blue bicycle was resting against the fence near the driveway. Morgan spoke with the resident at the front door and asked whether anyone needed medical help. The resident said that no staff were injured and that everyone was still inside the building.";
string interview = "Regarding the witness interview, Alex Rivera said the bicycle had been there since the previous evening. Alex had not seen anyone ride it or move it away from the fence during the morning. Morgan asked Alex to describe the lock without guessing who might have left it there. Alex described a silver lock with a red label and said there was no visible damage.";
string evidence = "Later that afternoon, Morgan photographed the bicycle and the silver lock from the public sidewalk. The photographs showed the position of the wheels, the open gate, and the red label on the lock. Morgan recorded the photographs as items 101 and 102 in the fictional training record. The bicycle remained in place, and no property was collected during the exercise.";
string source = arrival + " " + interview + " " + evidence;
string paragraphs = TextProcessing.Paragraphs(source);
Check("paragraphs preserve every word", Words(paragraphs) == Words(source));
Check("group related sentences", paragraphs.Contains("\n\nRegarding the witness") && paragraphs.Contains("\n\nLater that afternoon"));
Check("several sentences per paragraph", paragraphs.Split("\n\n").All(x => Regex.Matches(x, @"[.!?](?:\s|$)").Count >= 2));
foreach (string text in new[] { "I spoke to Sinton. No staff were injured.", "First topic.\n\nSecond topic.", "1. Check port 8080.\n2. Call Pesh.", "• First item.\n\n• Second item.\n\n• Third item.", "Dr. Lee checked version 7.2 with 👮🏽‍♀️ Sinton. It stayed at 45.6.", "" })
    Check("preserve short/list/Unicode: " + text.Length, TextProcessing.Paragraphs(text) == text);
string unicode = string.Concat(Enumerable.Repeat("李 👮🏽‍♀️ café 12345. ", 10000));
Check("long Unicode preserved", Words(TextProcessing.Paragraphs(unicode)) == Words(unicode));

var trigger = new Trigger();
Check("hold starts", trigger.Press(1000) == TriggerAction.Start);
Check("repeat ignored", trigger.Press(1100) == TriggerAction.None);
Check("release stops", trigger.Release(1800) == TriggerAction.Stop && !trigger.Recording);
trigger.Reset(); trigger.Press(2000); trigger.Release(2050);
Check("double tap 300ms", trigger.Press(2350) == TriggerAction.Continuous && trigger.Continuous);
Check("continuous release keeps recording", trigger.Release(2400) == TriggerAction.None && trigger.Recording);
Check("continuous stop tap down", trigger.Press(3000) == TriggerAction.None);
Check("continuous stop release", trigger.Release(3050) == TriggerAction.Stop && !trigger.Recording);
trigger.Reset(); trigger.Press(4000); trigger.Release(4050);
Check("tap outside window", trigger.Press(4351) == TriggerAction.Start && !trigger.Continuous);
Check("shortcut cancels capture", trigger.OtherKey() == TriggerAction.Cancel && trigger.Chord && !trigger.Recording);
Check("shortcut release does not process", trigger.Release(4400) == TriggerAction.None);
var gate = new OperationGate(); long first = gate.Start();
bool restartRefused = false; try { gate.Start(); } catch (InvalidOperationException) { restartRefused = true; }
Check("cancel/start waits for old cleanup", restartRefused && gate.Busy);
Check("old session drains", gate.Complete(first) && !gate.Busy);
long second = gate.Start(); Check("old finally cannot clear new session", !gate.Complete(first) && gate.Busy); gate.Complete(second);
var original = new FieldState(10, 20, "field-1", "Fictional prefix suffix", 16, 0);
foreach (var changed in new[] { original with { Window = 11 }, original with { Process = 21 }, original with { Element = "field-2" }, original with { Text = "changed" }, original with { Start = 0 }, original with { Length = 1 }, original with { Secure = true } }) {
    bool refused = false; try { FieldState.RequireUnchanged(original, changed); } catch (InvalidOperationException) { refused = true; }
    Check("changed or secure target refused " + changed.GetHashCode(), refused);
}
FieldState.RequireUnchanged(original, original);
string longNarration = string.Concat(Enumerable.Repeat("Fictional 李 👮🏽‍♀️ 123.\n\n", 10000));
Check("long Unicode insertion preserves prefix and suffix", original.Inserted(longNarration) == original.Text[..16] + longNarration + original.Text[16..]);

string directory = Path.Combine(Path.GetTempPath(), "pflow-fictional-" + Guid.NewGuid());
Check("observed insertion normalizes line endings only", TextProcessing.SameText("李\r\n\r\n123", "李\n\n123") && !TextProcessing.SameText("李\n123", "李\n124"));
var catalog = DictationTemplate.LegacyExamples();
Check("spoken template command", TemplateCommand.Parse("Please write this as an initial report. I arrived at 14:30.", catalog)?.Text == "I arrived at 14:30.");
Check("report mention inside narrative is not a command", TemplateCommand.Parse("I read a police report yesterday.", catalog) == null);
Check("template command preserves signed number", TemplateCommand.Parse("Use police report -12 degrees.", catalog)?.Text == "-12 degrees.");
Check("template command preserves decimal", TemplateCommand.Parse("Use police report .5 liters.", catalog)?.Text == ".5 liters.");
try {
    var store = new StateStore(directory);
    Check("clipboard defaults off", !store.Preferences.CopyDictationToClipboard);
    store.Preferences.Theme = "light"; store.Preferences.Waveform = "lines"; store.Preferences.CapsuleX = 123;
    store.Preferences.DictionaryReplacements.Add(Rule("peach", "Pesh")); store.SavePreferences();
    var reloaded = new StateStore(directory);
    Check("preferences persist", reloaded.Preferences.Theme == "light" && reloaded.Preferences.Waveform == "lines" && reloaded.Preferences.CapsuleX == 123);
    Check("dictionary format compatible", File.ReadAllText(Path.Combine(directory, "settings.json")).Contains("\"replacement\": \"Pesh\""));
    var t = JsonSerializer.Deserialize<DictationTemplate>("""{"id":"00000000-0000-0000-0000-000000000001","name":"Fixture","headingStyle":"uppercase","boldHeadings":true,"sections":[{"title":"Narrative","includeFullDictation":true}]}""", StateStore.Json)!;
    Check("Mac optional template fields", !t.NeedsAI && t.BoldHeadings == true && TextProcessing.RenderFullNarrative("Pesh 12.", t) == "NARRATIVE\nPesh 12.");
    var rich = RichText.Render("NARRATIVE body stays plain. 李 👮 {\\}", t);
    Check("bold only heading", rich.Rtf!.Contains(@"\b NARRATIVE\b0 ") && !rich.Rtf.Contains(@"\b NARRATIVE body"));
    Check("RTF Unicode and escapes", rich.Rtf.Contains(@"\u26446?") && rich.Rtf.Contains(@"\{\\\}"));
    Check("AI templates honestly require model", DictationTemplate.LegacyExamples().All(x => x.NeedsAI));
    bool rejected = false; try { TextProcessing.RenderFullNarrative("Training", DictationTemplate.LegacyExamples()[0]); } catch (InvalidOperationException) { rejected = true; }
    Check("no fake report extraction", rejected);
    var now = DateTimeOffset.Now;
    store.Add(new(Guid.NewGuid(), "Training one", now, 60, "Fixture", 120, "Notepad", "notepad", "Inserted"));
    store.Add(new(Guid.NewGuid(), "Training two", now, 120, "Fixture", 60, "Edge", "msedge", "Inserted"));
    store.Add(new(Guid.NewGuid(), "Legacy fixture", now, null, null, null, "Notepad", "notepad", "Saved"));
    var metrics = Usage.From(new StateStore(directory).History);
    Check("weighted speaking rate", metrics.WordsPerMinute == 60 && metrics.Seconds == 180 && metrics.Dictations == 3 && metrics.Words == 182);
    var deleteId = store.History[0].Id; store.Delete(deleteId);
    Check("delete persists", new StateStore(directory).History.All(x => x.Id != deleteId));
    store.Preferences.Theme = "invalid"; store.Preferences.Accent = "oops"; store.Preferences.Waveform = "invalid"; store.SavePreferences();
    Check("invalid preference fallback", store.Preferences.Theme == "dark" && store.Preferences.Accent == "FF9DC4" && store.Preferences.Waveform == "wave");
    File.WriteAllText(Path.Combine(directory, "settings.json"), "broken fixture");
    bool preserved = false; try { _ = new StateStore(directory); } catch (JsonException) { preserved = true; }
    Check("corrupt settings never overwritten", preserved && File.ReadAllText(Path.Combine(directory, "settings.json")) == "broken fixture");
} finally { Directory.Delete(directory, true); }
Console.WriteLine($"{passed} checks passed.");
