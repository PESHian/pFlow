namespace PFlow.Windows;

/// The whole-recording recognition failed; the message is the one shown to the person.
internal sealed class RecognitionFailure(string message, Exception? inner) : IOException(message, inner);

// One path for a stopped microphone recording and the native fictional-audio fixture.
internal sealed class DictationPipeline(StateStore store, Whisper whisper, LocalTextModel textModel)
{
    internal Action<string, double>? Timing { get; init; }
    async Task<T> Measure<T>(string name, Func<Task<T>> action)
    {
        var clock = Stopwatch.StartNew();
        try { return await action(); } finally { Timing?.Invoke(name, clock.Elapsed.TotalMilliseconds); }
    }
    internal TimeSpan CleanupBudget { get; init; } = TimeSpan.FromSeconds(8);
    internal readonly record struct Result(string Status, string? Notice);
    internal readonly record struct Prepared(string Text, string? Rtf, int SpokenWords, bool ReportUnavailable, bool CleanupIncomplete, bool CleanupTimedOut);
    internal async Task<Prepared> Prepare(string audio, double seconds, string folder, Action<Phase, string?> state, CancellationToken cancel)
    {
        state(Phase.Processing, "Transcribing");
        string raw;
        using (var transcription = CancellationTokenSource.CreateLinkedTokenSource(cancel)) {
            transcription.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(seconds * 2 + 30, 30, 3600)));
            try { raw = await Measure("recognitionMs", () => whisper.Transcribe(audio, store.Preferences.Language, store.Preferences.DictionaryTerms, transcription.Token)); }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new RecognitionFailure("Transcription took too long. Try a shorter recording.", null); }
            catch (Exception error) when (error is not OperationCanceledException) { throw new RecognitionFailure(error.Message, error); }
        }
        var preferences = store.Preferences;
        string text = TextProcessing.Replace(raw, preferences.DictionaryReplacements);
        bool localReady = preferences.UseLocalAI && textModel.FilesPresent, cleanupSkipped = false;
        var spoken = localReady ? TemplateCommand.Parse(text, preferences.Templates) : null;
        if (spoken != null && !string.IsNullOrWhiteSpace(spoken.Text)) text = spoken.Text;
        if (preferences.Cleanup) text = TextProcessing.RemoveFillers(text, preferences.DictionaryTerms, preferences.Language);
        bool aiCleanup = localReady && preferences.Cleanup && preferences.UseAICleanup && TextProcessing.SupportsEnglishCleanup(preferences.Language);
        if (aiCleanup) {
            state(Phase.Processing, "Cleaning up");
            using var cleanup = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            cleanup.CancelAfter(CleanupBudget);
            try { text = await Measure("cleanupMs", () => textModel.Cleanup(text, folder, cleanup.Token)); }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { cleanupSkipped = true; }
        }
        if (preferences.Paragraphs) text = TextProcessing.Paragraphs(text);
        var template = spoken?.Template ?? preferences.Templates.FirstOrDefault(x => x.Id == preferences.ActiveTemplateId);
        bool unavailable = template?.NeedsAI == true;
        string? rtf = null;
        if (template != null && localReady && template.NeedsAI) {
            state(Phase.Processing, "Formatting");
            using var formatting = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            formatting.CancelAfter(TimeSpan.FromSeconds(30));
            try {
                var report = await Measure("reportMs", () => textModel.Report(text, template, folder, formatting.Token));
                if (report != null) { text = report.Value.Text; rtf = report.Value.Rtf; unavailable = false; }
            } catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { }
        }
        else if (template != null && !template.NeedsAI) { var formatted = RichText.Render(text, template); text = formatted.Text; rtf = formatted.Rtf; }
        cancel.ThrowIfCancellationRequested();
        return new Prepared(text, rtf, TextProcessing.WordCount(raw), unavailable,
            aiCleanup && (cleanupSkipped || textModel.LastIssue != null), cleanupSkipped);
    }
    internal async Task<Result> Run(string audio, double seconds, InsertionTarget originalTarget, string folder,
        IntPtr owner, Action<Phase, string?> state, CancellationToken cancel, string? liveWords = null)
    {
        Prepared prepared;
        try { prepared = await Prepare(audio, seconds, folder, state, cancel); }
        catch (RecognitionFailure error) when (LiveTake.Recoverable(liveWords) is { } kept) {
            // Recognition of the whole take failed after live words appeared: keep them, say so, type nothing.
            store.Add(new Transcript(Guid.NewGuid(), kept, DateTimeOffset.Now, seconds, "Windows default microphone", TextProcessing.WordCount(kept),
                originalTarget.ApplicationName, originalTarget.ApplicationId, LiveTake.KeptStatus));
            state(Phase.Failed, LiveTake.KeptStatus);
            return new Result(LiveTake.KeptStatus, LiveTake.KeptStatus + " " + error.Message);
        }
        cancel.ThrowIfCancellationRequested();
        var preferences = store.Preferences;
        string text = prepared.Text; string? rtf = prepared.Rtf; bool unavailable = prepared.ReportUnavailable;
        var entry = new Transcript(Guid.NewGuid(), text, DateTimeOffset.Now, seconds, "Windows default microphone", prepared.SpokenWords, originalTarget.ApplicationName, originalTarget.ApplicationId, originalTarget.CanInsert ? "Pending insertion" : InsertionTarget.SavedToHistory);
        var history = Stopwatch.StartNew(); store.Add(entry); Timing?.Invoke("historySaveMs", history.Elapsed.TotalMilliseconds);
        if (originalTarget.CanInsert) state(Phase.Inserting, null);
        string result;
        try { result = await Measure("insertionMs", () => originalTarget.Insert(text, owner, preferences.CopyDictationToClipboard, cancel, rtf)); }
        catch (Exception error) when (error is not OperationCanceledException) { result = error.Message; }
        int index = store.History.FindIndex(x => x.Id == entry.Id);
        if (index >= 0) { store.History[index] = entry with { InsertionStatus = result }; store.Write("history.json", store.History); }
        bool inserted = result.StartsWith("Inserted", StringComparison.Ordinal);
        state(inserted ? Phase.Inserted : result == InsertionTarget.SavedToHistory ? Phase.Saved : Phase.Failed, result);
        string? notice = result != "Inserted" ? result : unavailable ? "Dictation inserted. AI report formatting did not finish; your words were kept."
            : prepared.CleanupIncomplete ? "Dictation inserted. Cleanup did not finish; your original words were kept." : null;
        return new Result(result, notice);
    }
}
