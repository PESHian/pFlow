using PFlow.Core;
using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// Live text: the same fixtures as the Mac app (fixtures/live-text, linked into
// the test output, never copied), settings, worker framing and the scheduler.
internal static class LiveTextChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
    static string Fixtures(string folder) => Path.Combine(AppContext.BaseDirectory, "live-text", folder);

    public static async Task<int> Run()
    {
        passed = 0;
        TranscriptFixtures(); WindowFixtures(); Settings(); Scheduler(); Resting(); Recovery(); PreviewText(); Placement();
        await Framing();
        Console.WriteLine($"{passed} live text checks passed.");
        return passed;
    }

    static void TranscriptFixtures()
    {
        var files = Directory.GetFiles(Fixtures("transcript-updates"), "*.json").OrderBy(x => x).ToArray();
        Check("all eight shared transcript fixtures are present", files.Select(Path.GetFileNameWithoutExtension).SequenceEqual(new[] {
            "before-begin", "corrections", "duplicates", "late-after-cancel", "late-after-finish", "reordered", "silence", "stale-session" }));
        foreach (var file in files) {
            var root = JsonNode.Parse(File.ReadAllText(file))!;
            var reconciler = new LiveTranscriptReconciler(); var shown = new List<string>();
            foreach (var step in root["events"]!.AsArray()) {
                switch ((string)step!["op"]!) {
                    case "begin": reconciler.Begin((string)step["session"]!); break;
                    case "cancel": reconciler.Cancel(); break;
                    case "update":
                        var update = new TranscriptUpdate((string)step["session"]!, (long)step["sequence"]!, (string)step["text"]!, (bool)step["isFinal"]!);
                        if (reconciler.Apply(update)) shown.Add(reconciler.Text);
                        break;
                    default: throw new Exception("Unknown fixture op in " + file);
                }
            }
            var expected = root["expected"]!;
            string name = Path.GetFileNameWithoutExtension(file);
            Check("transcript fixture shows the same texts: " + name, shown.SequenceEqual(expected["shown"]!.AsArray().Select(x => (string)x!)));
            Check("transcript fixture keeps the same text: " + name, reconciler.Text == (string)expected["text"]!);
            Check("transcript fixture ends in the same phase: " + name, reconciler.Phase.ToString().ToLowerInvariant() == (string)expected["phase"]!);
        }
    }

    static WhisperWindow Window(JsonNode node) => new((int)node["startMs"]!, (int)node["endMs"]!, node["segments"]!.AsArray().Select(segment =>
        new WhisperWindowSegment((int)segment!["fromMs"]!, (int)segment["toMs"]!, (string)segment["text"]!, (double)segment["noSpeechProbability"]!)).ToList());

    static void WindowFixtures()
    {
        var files = Directory.GetFiles(Fixtures("whisper-windows"), "*.json").OrderBy(x => x).ToArray();
        Check("all nine shared Whisper window fixtures are present", files.Select(Path.GetFileNameWithoutExtension).SequenceEqual(new[] {
            "boundary-correction", "long-session", "multilingual-chinese", "multilingual-spanish", "overlap-duplicates",
            "settled-boundary-repeat", "settled-segments", "silence-hallucination", "stale-window" }));
        foreach (var file in files) {
            var root = JsonNode.Parse(File.ReadAllText(file))!; var expected = root["expected"]!;
            string name = Path.GetFileNameWithoutExtension(file);
            var merger = new WhisperLiveMerger(); var after = new List<string>();
            foreach (var window in root["windows"]!.AsArray()) { merger.Apply(Window(window!)); after.Add(merger.Text); }
            if (expected["afterEach"] is JsonArray each)
                Check("window fixture matches after every window: " + name, after.SequenceEqual(each.Select(x => (string)x!)));
            if (expected["checkpoints"] is JsonArray checkpoints)
                Check("window fixture matches every checkpoint: " + name, checkpoints.Count > 0 && checkpoints.All(point => after[(int)point!["afterWindow"]!] == (string)point["text"]!));
            Check("window fixture ends with the same text: " + name, merger.Text == (string)expected["text"]!);
            Check("window fixture keeps the same words up to: " + name, merger.CommittedEndMs == (int)expected["committedEndMs"]!);
        }
    }

    static void Settings()
    {
        Check("Live text labels match the Mac app", LiveTextModes.All.Select(x => x.ToString()).SequenceEqual(new[] { "Off", "Preview in pFlow", "Type in the current app" }));
        Check("Live text is Off for new users", new Preferences().LiveTextMode == LiveTextModes.Off);
        foreach (string? unknown in new[] { null, "", "Off", "Preview", "inline", "type ", "on" }) {
            var preferences = new Preferences { LiveTextMode = unknown! }; preferences.Validate();
            Check($"unknown Live text value '{unknown}' becomes Off", preferences.LiveTextMode == LiveTextModes.Off);
        }
        string directory = Path.Combine(Path.GetTempPath(), "pflow-live-text-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            Directory.CreateDirectory(directory);
            string settings = Path.Combine(directory, "settings.json");
            // A copy of a settings file written before Live text existed; the original fixture is never touched.
            File.Copy(Path.Combine(AppContext.BaseDirectory, "settings-before-live-text.json"), settings);
            string original = File.ReadAllText(settings);
            var store = new StateStore(directory);
            Check("settings from before Live text load as Off", store.Preferences.LiveTextMode == LiveTextModes.Off);
            Check("loading old settings does not rewrite them", File.ReadAllText(settings) == original);
            var before = JsonNode.Parse(original)!.AsObject();
            var loaded = JsonNode.Parse(JsonSerializer.Serialize(store.Preferences, StateStore.Json))!.AsObject();
            var changed = before.Where(pair => !JsonNode.DeepEquals(pair.Value, loaded[pair.Key])).Select(pair => pair.Key).ToList();
            Check("every earlier setting survives unchanged " + string.Join(",", changed), changed.Count == 0);
            Check("the only new setting is Live text", loaded.Select(x => x.Key).Except(before.Select(x => x.Key)).SequenceEqual(new[] { "liveTextMode" }));
            store.Preferences.LiveTextMode = LiveTextModes.Preview; store.SavePreferences();
            Check("Preview in pFlow persists", new StateStore(directory).Preferences.LiveTextMode == LiveTextModes.Preview);
            store.Preferences.LiveTextMode = LiveTextModes.TypeInApp; store.SavePreferences();
            var reopened = new StateStore(directory).Preferences;
            Check("Type in the current app persists with other settings intact", reopened.LiveTextMode == LiveTextModes.TypeInApp && reopened.Language == "es" && reopened.Templates.Single().Name == "Garden log");
            File.WriteAllText(settings, File.ReadAllText(settings).Replace("\"liveTextMode\": \"type\"", "\"liveTextMode\": \"sideways\""));
            Check("an unknown saved Live text value loads as Off", new StateStore(directory).Preferences.LiveTextMode == LiveTextModes.Off);
            Check("Type in the current app also shows the preview", LiveTextModes.ShowsPreview(LiveTextModes.TypeInApp) && LiveTextModes.ShowsPreview(LiveTextModes.Preview) && !LiveTextModes.ShowsPreview("sideways"));
        } finally { Directory.Delete(directory, true); }
    }

    static short[] Tone(int milliseconds, double amplitude = .2) =>
        Enumerable.Range(0, milliseconds * 16).Select(i => (short)(Math.Sin(i * 2 * Math.PI * 220 / 16000) * amplitude * 32767)).ToArray();

    static void Scheduler()
    {
        var session = new LiveSession(7);
        session.Append(Tone(900));
        Check("no window before a second of audio", session.Next() == null);
        session.Append(Tone(300));
        var first = session.Next();
        Check("first window covers the audio so far", first != null && first.StartSample == 0 && first.EndSample == 1200 * 16 && first.Samples.Length == 1200 * 16);
        session.Append(Tone(5000));
        Check("at most one window runs at a time", session.Next() == null && session.Busy);
        var update = session.Complete(first!, [new(0, 1200, " Marigold", .05)]);
        Check("a finished window updates the live text", update != null && update.Text == "Marigold" && update.Session == "7" && update.Sequence == 0 && !update.IsFinal);
        Check("a repeated reply for the same window is ignored", session.Complete(first!, [new(0, 1200, " Other", .05)]) == null);
        var second = session.Next();
        Check("audio that arrived while busy is coalesced into one window of the newest audio", second != null && second.EndSample == 6200 * 16 && second.Sequence == 1);
        var foreign = new LiveSession(8); foreign.Append(Tone(1500)); var other = foreign.Next()!;
        Check("a reply for another take is ignored", session.Complete(other, [new(0, 1000, " stray", .05)]) == null && session.Busy);
        session.Abandon(second!);
        Check("a canceled window frees the slot", !session.Busy);
        session.Append(Tone(1000));
        var third = session.Next()!;
        Check("sequences keep increasing after a canceled window", third.Sequence == 2);
        string kept = session.Close();
        Check("a reply after stop is discarded", session.Complete(third, [new(0, 1000, " late words", .05)]) == null && session.Text == kept && kept == "Marigold");
        Check("nothing is planned after stop", session.Next() == null);

        var quiet = new LiveSession(9);
        quiet.Append(new short[16 * 3000]);
        Check("silence runs no inference", quiet.Next() == null && quiet.Inferences == 0 && quiet.SilentWindows == 1);

        // A long take: every window stays bounded and the ring never grows.
        var longTake = new LiveSession(10); int largest = 0; long previousEnd = 0; bool ordered = true;
        for (int second2 = 0; second2 < 330; second2++) {
            longTake.Append(Tone(1000));
            if (longTake.Next() is { } window) {
                largest = Math.Max(largest, window.Samples.Length); ordered &= window.EndSample > previousEnd; previousEnd = window.EndSample;
                longTake.Complete(window, [new(0, (int)((window.EndSample - window.StartSample) / 16), " word" + second2, .05)]);
            }
        }
        Check("a 330 s take never sends a window over 15 s", largest > 0 && largest <= 15_000 * 16);
        Check("windows only move forward", ordered && longTake.Inferences > 300);
        Check("the audio ring holds 20 s however long the take", longTake.RingCapacity == 20 * 16_000 && longTake.TotalSamples == 330L * 16_000);

        var failing = new LiveSession(11); failing.Append(Tone(1500)); var lost = failing.Next()!;
        failing.Complete(lost, [new(0, 1500, " Quiet harbor", .05)]);
        failing.Append(Tone(1000)); var broken = failing.Next()!;
        failing.Fail();
        Check("after a live failure nothing more is planned and the words stay", failing.Next() == null && failing.Text == "Quiet harbor" && failing.Complete(broken, [new(0, 1000, " later", .05)]) == null);
    }

    /// Live recognition rests as long as each window took. Time comes from a
    /// test clock; audio is appended as it would arrive.
    static void Resting()
    {
        long now = 0;
        var take = new LiveSession(20, clock: () => now);
        take.Append(Tone(1000));
        var slow = take.Next()!;
        Check("the first window starts at once", slow != null && slow.Sequence == 0);
        now = 900; take.Append(Tone(1000));
        take.Complete(slow!, [new(0, 1000, " Copper", .05)]);
        Check("after a 900 ms window nothing starts during the next 900 ms", take.Next() == null && !take.Busy);
        now = 1799; Check("still resting 1 ms before the rest ends", take.Next() == null);
        now = 1800; var next = take.Next();
        Check("the next window starts when the rest ends and covers the newest audio", next != null && next.EndSample == 2000 * 16);

        // A fast machine: a 100 ms window never holds the next one back.
        now = 1900; take.Complete(next!, [new(0, 2000, " Copper kettle", .05)]);
        now = 2900; take.Append(Tone(1000));
        Check("a quick window is followed by the next one as soon as there is a second of new audio", take.Next() != null);

        // Cancel: an abandoned slow window rests too, and stopping during a rest keeps the words.
        long clock2 = 0; var canceled = new LiveSession(21, clock: () => clock2);
        canceled.Append(Tone(1000)); var first = canceled.Next()!;
        clock2 = 800; canceled.Abandon(first); canceled.Append(Tone(1000));
        Check("a canceled slow window does not restart back to back", canceled.Next() == null && !canceled.Busy);
        Check("stopping during a rest ends the take with its words", canceled.Close() == "" && canceled.Next() == null);
        clock2 = 10_000; Check("nothing is planned after stop, even once the rest is over", canceled.Next() == null);

        // Device change: the recorder pauses while the new microphone opens, then audio resumes.
        long clock3 = 0; var device = new LiveSession(22, clock: () => clock3);
        device.Append(Tone(1000)); var before = device.Next()!;
        clock3 = 700; device.Complete(before, [new(0, 1000, " Harbor", .05)]);
        clock3 = 4000; Check("no audio during the switch plans nothing", device.Next() == null);
        device.Append(Tone(300)); device.Append(Tone(400)); device.Append(Tone(300));
        var after = device.Next();
        Check("audio from the new device is recognized once a second has arrived", after != null && after.EndSample == 2000 * 16 && after.Sequence == 1);

        // Language change applies from the next take: a new take never waits for the last one's rest.
        long clock4 = 0; var english = new LiveSession(23, clock: () => clock4);
        english.Append(Tone(1000)); var englishWindow = english.Next()!;
        clock4 = 1500; english.Complete(englishWindow, [new(0, 1000, " Lantern", .05)]); english.Close();
        var spanish = new LiveSession(24, clock: () => clock4); spanish.Append(Tone(1000));
        Check("the next take starts its first window at once", spanish.Next() is { Sequence: 0 } && english.Next() == null);
    }

    static void Recovery()
    {
        Check("live words are kept when the final pass fails", LiveTake.Recoverable("  Copper kettle  ") == "Copper kettle");
        Check("no live words means nothing to keep", LiveTake.Recoverable(null) == null && LiveTake.Recoverable(" \n ") == null);
        Check("kept words say plainly nothing was typed", LiveTake.KeptStatus.Contains("Kept in History") && LiveTake.KeptStatus.Contains("nothing was typed"));
    }

    static void PreviewText()
    {
        string story = string.Join(" ", Enumerable.Range(0, 120).Select(i => "lantern" + i));
        string tail = LivePreviewText.Tail(story);
        Check("a long narration shows a bounded tail", tail.StartsWith('…') && tail.Length <= 241 && story.EndsWith(tail[1..]));
        Check("the tail never opens on half a word", story.Split(' ').Contains(tail[1..].Split(' ')[0]));
        Check("short text shows as is", LivePreviewText.Tail("  Quiet river  ") == "Quiet river");
    }

    static void Placement()
    {
        var left = new WorkArea(0, 0, 1920, 1040); var right = new WorkArea(1920, 0, 2560, 1400);
        var (x, y) = LivePreviewPlacement.Place([left, right], new WorkArea(1920 + 1220, 1200, 120, 32), 570, 150, 12);
        Check("preview sits above the control on the control's display", x == 1920 + 1220 + 60 - 285 && y == 1200 - 12 - 150);
        (x, y) = LivePreviewPlacement.Place([left, right], new WorkArea(900, 10, 120, 32), 570, 150, 12);
        Check("no room above puts the preview below the control", y == 10 + 32 + 12 && x >= 0 && x + 570 <= 1920);
        (x, y) = LivePreviewPlacement.Place([left], new WorkArea(1850, 900, 120, 32), 570, 150, 12);
        Check("the preview stays inside the work area", x == 1920 - 570 && y == 900 - 12 - 150);
        (x, _) = LivePreviewPlacement.Place([new WorkArea(0, 0, 320, 480)], new WorkArea(100, 400, 120, 32), 400, 150, 12);
        Check("a display narrower than the preview starts it at the left edge", x == 0);
    }

    static byte[] Reply(uint kind, uint version, uint session, uint sequence, Action<BinaryWriter> body)
    {
        using var data = new MemoryStream(); using (var writer = new BinaryWriter(data, Encoding.UTF8, true)) {
            writer.Write(kind); writer.Write(version); writer.Write(session); writer.Write(sequence); body(writer);
        }
        return data.ToArray();
    }
    static void Segment(BinaryWriter writer, int from, int to, float noSpeech, byte[] text) { writer.Write(from); writer.Write(to); writer.Write(noSpeech); writer.Write(text.Length); writer.Write(text); }
    static byte[] Result(uint session, uint sequence, params (int From, int To, string Text)[] segments) => Reply(LiveWorkerProtocol.Result, LiveWorkerProtocol.Version, session, sequence, writer => {
        writer.Write(segments.Length); foreach (var s in segments) Segment(writer, s.From, s.To, .05f, Encoding.UTF8.GetBytes(s.Text)); writer.Write(12.5);
    });
    static async Task<bool> Rejected(byte[] bytes, uint session = 1, uint sequence = 1)
    {
        try { await LiveWorkerProtocol.ReadReply(new MemoryStream(bytes), session, sequence, CancellationToken.None); return false; }
        catch (InvalidDataException) { return true; }
        catch (EndOfStreamException) { return true; }
    }

    static async Task Framing()
    {
        var request = LiveWorkerProtocol.EncodeRequest(3, 4, "es", new float[] { .5f, -.25f });
        Check("live request carries its magic, version, take and window", BinaryPrimitives.ReadUInt32LittleEndian(request) == 0x31534650
            && BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(4)) == 2 && BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(8)) == 3 && BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(12)) == 4);
        Check("live request carries the language and samples exactly", request.Length == 20 + 2 + 4 + 8 && Encoding.UTF8.GetString(request, 20, 2) == "es"
            && BinaryPrimitives.ReadUInt32LittleEndian(request.AsSpan(22)) == 2 && BinaryPrimitives.ReadSingleLittleEndian(request.AsSpan(26)) == .5f);
        Check("cancel frame names its window", LiveWorkerProtocol.EncodeCancel(3, 4).SequenceEqual(Reply(0x31434650, 2, 3, 4, _ => { })));
        bool Throws(Action action) { try { action(); return false; } catch (InvalidDataException) { return true; } }
        Check("empty and oversized windows are never sent", Throws(() => LiveWorkerProtocol.EncodeRequest(1, 1, "en", [])) && Throws(() => LiveWorkerProtocol.EncodeRequest(1, 1, "en", new float[30 * 16000 + 1])));
        Check("an empty or oversized language is never sent", Throws(() => LiveWorkerProtocol.EncodeRequest(1, 1, "", new float[1])) && Throws(() => LiveWorkerProtocol.EncodeRequest(1, 1, new string('e', 65), new float[1])));

        var (good, skipped) = await LiveWorkerProtocol.ReadReply(new MemoryStream(Result(1, 1, (0, 900, " Brave turtles"), (900, 1800, " 游泳"))), 1, 1, CancellationToken.None);
        Check("a well-formed reply is read", skipped == 0 && good.Segments!.Count == 2 && good.Segments[1].Text == " 游泳" && good.Segments[0].ToMs == 900 && good.Milliseconds == 12.5);
        var error = Reply(LiveWorkerProtocol.Error, 2, 1, 1, writer => { var text = Encoding.UTF8.GetBytes("Canceled."); writer.Write(text.Length); writer.Write(text); });
        var (canceled, _) = await LiveWorkerProtocol.ReadReply(new MemoryStream(error), 1, 1, CancellationToken.None);
        Check("an error reply is read as an error, not words", canceled.Segments == null && canceled.Error == "Canceled.");

        Check("an older protocol version is rejected", await Rejected(Reply(LiveWorkerProtocol.Result, 1, 1, 1, writer => { writer.Write(0); writer.Write(1.0); })));
        Check("a whole-recording reply where a live reply belongs is rejected", await Rejected(Reply(2, 2, 1, 1, writer => writer.Write(0))));
        Check("an unknown reply kind is rejected", await Rejected(Reply(9, 2, 1, 1, _ => { })));
        Check("garbage is rejected", await Rejected(Encoding.ASCII.GetBytes("not a pFlow worker reply at all")));
        Check("too many segments are rejected", await Rejected(Reply(4, 2, 1, 1, writer => writer.Write(513))));
        Check("an oversized segment text is rejected before it is read", await Rejected(Reply(4, 2, 1, 1, writer => { writer.Write(1); Segment(writer, 0, 10, .1f, Encoding.ASCII.GetBytes(new string('a', 4097))); writer.Write(1.0); })));
        Check("too much text overall is rejected", await Rejected(Reply(4, 2, 1, 1, writer => { writer.Write(100); for (int i = 0; i < 100; i++) Segment(writer, 0, 10, .1f, Encoding.ASCII.GetBytes(new string('a', 4096))); writer.Write(1.0); })));
        Check("text that is not UTF-8 is rejected", await Rejected(Reply(4, 2, 1, 1, writer => { writer.Write(1); Segment(writer, 0, 10, .1f, [0xFF, 0xFE]); writer.Write(1.0); })));
        Check("a non-number no-speech value is rejected", await Rejected(Reply(4, 2, 1, 1, writer => { writer.Write(1); Segment(writer, 0, 10, float.NaN, Encoding.ASCII.GetBytes("x")); writer.Write(1.0); })));
        var truncated = Result(1, 1, (0, 900, " Brave turtles"));
        Check("a reply cut short is rejected", await Rejected(truncated[..^5]));

        // Sequence numbers start again each take, so the older take's late reply
        // carries the same sequence as the current request; only the take tells them apart.
        var late = Result(2, 1, (0, 900, " old window")).Concat(Result(1, 2, (0, 900, " old take"))).Concat(Result(2, 2, (0, 900, " current"))).ToArray();
        var (current, discarded) = await LiveWorkerProtocol.ReadReply(new MemoryStream(late), 2, 2, CancellationToken.None);
        Check("late replies for older windows and takes are discarded", discarded == 2 && current.Segments!.Single().Text == " current");
        var flood = Enumerable.Range(0, 3).SelectMany(i => Result(1, (uint)i, (0, 900, " old"))).Concat(Result(1, 5, (0, 900, " current"))).ToArray();
        Check("more stale replies than the limit end the worker", await Rejected(flood, 1, 5));
    }
}
