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
    internal const string CopyFailed = "Inserted, but it could not be copied to the clipboard. Copy it from History.";
    /// `Prompt` carries the words for pFlow's "couldn't type this" card, with the
    /// reason line, whenever the words did not go into the app (one rule: InsertionPrompt.Offer).
    internal readonly record struct Result(string Status, string? Notice, (string Text, string Reason)? Prompt = null);
    internal readonly record struct Prepared(string Text, string? Rtf, int SpokenWords, bool ReportUnavailable);
    internal async Task<Prepared> Prepare(string audio, double seconds, string folder, Action<Phase, string?> state, CancellationToken cancel)
    {
        state(Phase.Processing, "Transcribing");
        string raw;
        using (var transcription = CancellationTokenSource.CreateLinkedTokenSource(cancel)) {
            // The worker reports progress about once a second and SpeechWorker ends one that goes
            // quiet (StallLimit), so a slow processor is never cut off while it is still working.
            // This outer limit only bounds the whole wait: ten times the recording plus two minutes.
            transcription.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(seconds * 10 + 120, 120, 3600)));
            try { raw = await Measure("recognitionMs", () => whisper.Transcribe(audio, store.Preferences.Language, store.Preferences.DictionaryTerms, transcription.Token)); }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new RecognitionFailure("Transcription took too long. Try a shorter recording.", null); }
            catch (Exception error) when (error is not OperationCanceledException) { throw new RecognitionFailure(error.Message, error); }
        }
        return await Shape(raw, folder, state, cancel);
    }
    /// Dictionary, cleanup (the rule-based one: fillers, capitals and spacing), paragraphs and
    /// templates, once, on the whole take's words. The local text model only sorts sentences into a
    /// report template's sections; it never rewrites dictation.
    internal async Task<Prepared> Shape(string raw, string folder, Action<Phase, string?> state, CancellationToken cancel)
    {
        var preferences = store.Preferences;
        string text = TextProcessing.Replace(raw, preferences.DictionaryReplacements);
        bool localReady = preferences.UseLocalAI && textModel.FilesPresent;
        var spoken = localReady ? TemplateCommand.Parse(text, preferences.Templates) : null;
        if (spoken != null && !string.IsNullOrWhiteSpace(spoken.Text)) text = spoken.Text;
        if (preferences.Cleanup) text = TextProcessing.RemoveFillers(text, preferences.DictionaryTerms, preferences.Language);
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
        return new Prepared(text, rtf, TextProcessing.WordCount(raw), unavailable);
    }
    internal async Task<Result> Run(string audio, double seconds, IInsertionTarget originalTarget, string folder,
        IntPtr owner, Action<Phase, string?> state, CancellationToken cancel, string? liveWords = null, LiveTyping? typing = null)
    {
        Prepared prepared;
        try { prepared = await Prepare(audio, seconds, folder, state, cancel); }
        catch (RecognitionFailure error) when (LiveTake.Recoverable(liveWords) is { } kept) {
            // Recognition of the whole take failed after live words appeared: keep them, say so, type nothing more.
            bool typed = typing?.Typed() == true;
            string status = typed ? LiveInlineText.KeptTyped : LiveTake.KeptStatus;
            store.Add(new Transcript(Guid.NewGuid(), kept, DateTimeOffset.Now, seconds, "Windows default microphone", TextProcessing.WordCount(kept),
                originalTarget.ApplicationName, originalTarget.ApplicationId, status));
            state(Phase.Failed, status);
            return new Result(status, status + " " + error.Message, InsertionPrompt.Offer(kept, status, typed));
        }
        return await Deliver(prepared, seconds, originalTarget, owner, state, cancel, typing);
    }
    /// Saves one History entry and puts the finished text in once: over the
    /// words typed live when this take typed any, otherwise the normal way.
    internal async Task<Result> Deliver(Prepared prepared, double seconds, IInsertionTarget originalTarget,
        IntPtr owner, Action<Phase, string?> state, CancellationToken cancel, LiveTyping? typing = null)
    {
        cancel.ThrowIfCancellationRequested();
        var preferences = store.Preferences;
        string text = prepared.Text; string? rtf = prepared.Rtf; bool unavailable = prepared.ReportUnavailable;
        // A take that ends with no words takes its live words back out.
        if (typing != null && string.IsNullOrWhiteSpace(text)) { typing.Cancel(); typing = null; }
        var entry = new Transcript(Guid.NewGuid(), text, DateTimeOffset.Now, seconds, "Windows default microphone", prepared.SpokenWords, originalTarget.ApplicationName, originalTarget.ApplicationId, originalTarget.CanInsert ? "Pending insertion" : InsertionTarget.SavedToHistory);
        var history = Stopwatch.StartNew(); store.Add(entry); Timing?.Invoke("historySaveMs", history.Elapsed.TotalMilliseconds);
        if (originalTarget.CanInsert) state(Phase.Inserting, null);
        string? result = null; bool kept = false;
        if (typing != null) {
            // Plain text replaces the provisional words once; styles cannot be set through a text range.
            var clock = Stopwatch.StartNew(); var (final, stop) = typing.Finalize(text); Timing?.Invoke("insertionMs", clock.Elapsed.TotalMilliseconds);
            if (final == LiveFinal.Applied) {
                result = rtf != null ? InsertionTarget.PlainOnly : "Inserted";
                // The finished words only, once; the live words never touch the clipboard.
                if (preferences.CopyDictationToClipboard) {
                    try { ClipboardLease.KeepCopy(owner, text); }
                    catch (Exception error) when (error is InvalidOperationException or OutOfMemoryException) { result = CopyFailed; }
                }
            }
            else if (final == LiveFinal.Kept) { result = LiveInlineText.Kept(stop ?? LiveStop.Uncertain); kept = true; }
        }
        if (result == null) {
            try { result = await Measure("insertionMs", () => originalTarget.Insert(text, owner, preferences.CopyDictationToClipboard, cancel, rtf)); }
            catch (Exception error) when (error is not OperationCanceledException) { result = error.Message; InsertionLog.Record("insert failed: " + InsertionLog.Reason(error)); }
        } else InsertionLog.Record("live typing final: " + result);
        int index = store.History.FindIndex(x => x.Id == entry.Id);
        if (index >= 0) { store.History[index] = entry with { InsertionStatus = result }; store.Write("history.json", store.History); }
        // Words typed without a check went in the way a person's typing would: that is a done take, not a failure.
        bool inserted = result.StartsWith("Inserted", StringComparison.Ordinal) || result.StartsWith(InsertionTarget.Unchecked, StringComparison.Ordinal);
        // A write that went out but could not be read back is nearly always in the field already (web
        // boxes read back late): no balloon and no card for it; the History status says to check.
        bool unconfirmed = result.StartsWith(InsertionTarget.Unconfirmed, StringComparison.Ordinal);
        state(inserted ? Phase.Inserted : kept || unconfirmed || result is InsertionTarget.SavedToHistory or InsertionTarget.Unreachable ? Phase.Saved : Phase.Failed, result);
        // Anything short of a done take is said every time; words that never went in are shown in the card to copy.
        string? notice = !inserted ? unconfirmed ? null : result : unavailable ? "Dictation inserted. AI report formatting did not finish; your words were kept." : null;
        return new Result(result, notice, unconfirmed ? null : InsertionPrompt.Offer(text, result, kept));
    }
}

/// One take's live typing, as the pipeline sees it at the end of the take.
internal sealed record LiveTyping(Func<string, (LiveFinal Result, LiveStop? Stop)> Finalize, Func<bool> Typed, Func<(LiveCancel Result, LiveStop? Stop)> Cancel);
