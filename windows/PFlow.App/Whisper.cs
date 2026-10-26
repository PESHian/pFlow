
namespace PFlow.Windows;

internal sealed class Whisper : IAsyncDisposable
{
    readonly string root;
    readonly string assets;
    readonly SemaphoreSlim modelLock = new(1);
    readonly CancellationTokenSource lifetime = new();
    SpeechWorker? worker;
    internal SpeechMetrics LastMetrics { get; private set; }
    internal int? WorkerId => worker?.Id;
    internal int WorkerStartHeartbeats => worker?.StartHeartbeats ?? 0;
    internal double WorkerLoadMs => worker?.LoadMs ?? 0;
    /// Progress frames the current worker sent during finished-text passes.
    internal int WorkerHeartbeats => worker?.Heartbeats ?? 0;
    /// Whisper small, the one speech model (SpeechModels.Small): a copy in pFlow's own folder when an
    /// earlier version downloaded one there and it is whole, else the package's (always installed). Checked
    /// by size here and by size and hash when the worker starts; an own copy that fails either is passed
    /// over for the package's, and Settings and the log say so.
    public string ModelPath => OwnCopy == OwnCopyState.Usable ? OwnCopyPath : PackagePath;
    string OwnCopyPath => System.IO.Path.Combine(root, SpeechModels.Small.FileName);
    string PackagePath => System.IO.Path.Combine(assets, "models", SpeechModels.Small.FileName);
    internal enum OwnCopyState { None, Usable, WrongSize, Damaged }
    bool ownCopyDamaged;
    internal OwnCopyState OwnCopy => !File.Exists(OwnCopyPath) ? OwnCopyState.None : ownCopyDamaged || DamagedBefore() ? OwnCopyState.Damaged
        : new FileInfo(OwnCopyPath).Length != SpeechModels.Small.Bytes ? OwnCopyState.WrongSize : OwnCopyState.Usable;
    /// A failed checksum is remembered for that very file (its size and last-write time), so a damaged
    /// own copy is not hashed again at every start; a changed file is checked again.
    string VerdictPath => System.IO.Path.Combine(root, "small-own-copy-damaged.txt");
    static string Stamp(FileInfo file) => file.Length + " " + file.LastWriteTimeUtc.Ticks;
    bool DamagedBefore()
    {
        try { return File.Exists(VerdictPath) && File.ReadAllText(VerdictPath).Trim() == Stamp(new FileInfo(OwnCopyPath)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }
    internal void MarkOwnCopyDamaged()
    {
        ownCopyDamaged = true;
        try { File.WriteAllText(VerdictPath, Stamp(new FileInfo(OwnCopyPath))); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    /// For Settings and the diagnostic report: null while nothing is wrong.
    internal string? OwnCopyNote => OwnCopy is OwnCopyState.WrongSize or OwnCopyState.Damaged
        ? "pFlow's own copy of Whisper small is damaged, so the copy included with pFlow is used." : null;
    internal string ModelSource => OwnCopy switch {
        OwnCopyState.Usable => "pFlow's own copy", OwnCopyState.WrongSize => "the package's (own copy has the wrong size)",
        OwnCopyState.Damaged => "the package's (own copy failed its checksum)", _ => "the package's" };
    /// The small live-words model next to the main model, or null when it is not installed (then live
    /// windows run on the main model and Settings says so). Checked by size and hash when the worker starts.
    public string? LiveModelPath { get { string path = System.IO.Path.Combine(assets, "models", LiveSpeechModel.FileName); return File.Exists(path) ? path : null; } }
    public bool LiveModelPresent => LiveModelPath != null;
    /// Live words really run on the live model: the file is there and the last worker start accepted it.
    public bool LiveModelReady => worker is { Exited: false } w ? w.LiveModelLoaded : LiveModelPresent && !SpeechWorker.LiveModelRejected;
    /// The AVX2 build on x64 processors that have it, else the baseline build (one rule: SpeechEngine.Choose).
    public string Executable => System.IO.Path.Combine(assets, "engine", SpeechEngine.Choose(
        RuntimeInformation.ProcessArchitecture == Architecture.X64, Native.Avx2Ready, name => File.Exists(System.IO.Path.Combine(assets, "engine", name))));
    /// Removes unfinished speech model downloads an earlier version left in pFlow's folder.
    public int SweepPartials() => PartialDownloads.Sweep(root, SpeechModels.Small.FileName) + SpeechModels.RetiredFiles.Sum(file => PartialDownloads.Sweep(root, file));
    /// Deletes the speech models 0.1.25 could download and 0.1.26 removed (SpeechModels.RetiredFiles),
    /// only those exact files in pFlow's own folder, and their unfinished downloads. Returns the names
    /// removed; the log gets the file names only, never a path.
    /// Only a file with the very size and SHA-256 pFlow downloaded is deleted (`retired` stands in for
    /// SpeechModels.Retired in a test); anything else under that name is left and logged.
    public IReadOnlyList<string> RemoveRetiredModels(IReadOnlyList<SpeechModel>? retired = null)
    {
        var removed = new List<string>();
        foreach (var model in retired ?? SpeechModels.Retired) {
            string file = model.FileName, path = System.IO.Path.Combine(root, file);
            try {
                if (File.Exists(path)) {
                    if (!Downloaded(path, model)) InsertionLog.Record("retired speech model name kept: " + file + " is not the file pFlow downloaded (size or checksum differs)");
                    else { File.Delete(path); removed.Add(file); }
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { InsertionLog.Record("retired speech model not removed: " + file + " (" + error.GetType().Name + ")"); }
            int partial = PartialDownloads.Sweep(root, file);
            if (partial > 0) removed.Add(file + " (unfinished download x" + partial + ")");
        }
        if (removed.Count > 0) InsertionLog.Record("removed retired speech models: " + string.Join(", ", removed));
        return removed;
    }
    static bool Downloaded(string path, SpeechModel model)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.SequentialScan);
        if (file.Length != model.Bytes) return false;
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(file)).Equals(model.Sha, StringComparison.OrdinalIgnoreCase);
    }
    public bool FilesPresent => File.Exists(ModelPath) && new FileInfo(ModelPath).Length == SpeechModels.Small.Bytes && File.Exists(Executable);
    /// For Settings: "x64, fast speech engine (AVX2)" and the like (one rule: SpeechEngine.Describe).
    public string EngineDescription => SpeechEngine.Describe(RuntimeInformation.ProcessArchitecture.ToString(), System.IO.Path.GetFileName(Executable), LiveModelReady);
    public Whisper(string root, string? assetsRoot = null) { this.root = root; assets = assetsRoot ?? AppContext.BaseDirectory; }
    void ResetWorker() { worker?.Dispose(); worker = null; }
    /// A live worker is kept for every take; one that was lost is replaced (as 0.1.23 did, one model).
    async Task EnsureWorker(CancellationToken cancel)
    {
        if (worker != null && !worker.Exited) return;
        ResetWorker();
        string model = ModelPath; var clock = Stopwatch.StartNew();
        try {
            try { worker = await SpeechWorker.Start(Executable, model, LiveModelPath, cancel); }
            catch (InvalidDataException) when (model == OwnCopyPath) {
                // pFlow's own copy failed its size or checksum: the package's copy is used from now on.
                MarkOwnCopyDamaged(); InsertionLog.Record("own copy of Whisper small failed its check; using the package's copy");
                worker = await SpeechWorker.Start(Executable, ModelPath, LiveModelPath, cancel);
            }
            Diagnostics.Recorder.Event("worker.start", new DiagField("result", "ready"), new DiagField("ms", clock.ElapsedMilliseconds), new DiagField("loadMs", worker.LoadMs),
                new DiagField("progressFrames", worker.StartHeartbeats), new DiagField("engine", System.IO.Path.GetFileName(Executable)), new DiagField("model", ModelSource),
                new DiagField("liveModel", LiveModelPath == null ? "missing" : worker.LiveModelLoaded ? "loaded" : "rejected (size or checksum)"),
                new DiagField("threads", SpeechThreads.Final(SpeechWorker.LogicalProcessors) + " final / " + SpeechThreads.Live(SpeechWorker.LogicalProcessors) + " live"));
        } catch (Exception error) {
            Diagnostics.Recorder.Event("worker.start", new DiagField("result", "failed"), new DiagField("ms", clock.ElapsedMilliseconds), new DiagField("reason", PrivateLog.Reason(error)));
            throw;
        }
    }
    internal async Task Prewarm(CancellationToken cancel = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancel, lifetime.Token);
        await modelLock.WaitAsync(linked.Token);
        try { if (FilesPresent) await EnsureWorker(linked.Token); }
        finally { modelLock.Release(); }
    }
    public async Task<string> Transcribe(string audio, string language, IEnumerable<string> vocabulary, CancellationToken cancel)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancel, lifetime.Token); cancel = linked.Token;
        if (!File.Exists(Executable)) throw new FileNotFoundException("The Windows speech engine is missing. Install a complete pFlow package.");
        await modelLock.WaitAsync(cancel);
        try {
            // A worker that was lost (failed start, quiet model load, death under the pass) gets one fresh try:
            // the finished text must come whenever recognition can complete. Worker-reported errors and the
            // caller's own cancel are not retried.
            for (int attempt = 1; ; attempt++) {
                try { return await TranscribeOnce(audio, language, vocabulary, cancel); }
                catch (SpeechWorkerLost) when (attempt == 1 && !cancel.IsCancellationRequested) { Retries++; ResetWorker(); }
            }
        } catch when (cancel.IsCancellationRequested) { ResetWorker(); throw new OperationCanceledException(cancel); }
        catch { ResetWorker(); throw; }
        finally { modelLock.Release(); }
    }
    /// Finished-text passes that needed a second worker.
    internal int Retries { get; private set; }
    async Task<string> TranscribeOnce(string audio, string language, IEnumerable<string> vocabulary, CancellationToken cancel)
    {
        bool reused = worker != null && !worker.Exited; var watch = Stopwatch.StartNew();
        LastMetrics = default; await EnsureWorker(cancel); double initialization = watch.Elapsed.TotalMilliseconds;
        var terms = string.Join(", ", vocabulary.Where(x => !string.IsNullOrWhiteSpace(x))).Trim();
        var result = await worker!.Transcribe(audio, language, terms[..Math.Min(terms.Length, 2000)], cancel);
        LastMetrics = result.Metrics with { Reused = reused, InitializationMs = initialization };
        string text = result.Text.Trim();
        if (string.IsNullOrWhiteSpace(text)) throw new IOException("No speech was found. Check the microphone and try again.");
        return TextProcessing.JoinRecognitionLines(text);
    }
    /// Live windows sent to the worker; Off never sends any.
    internal int LiveRequests => Volatile.Read(ref liveRequests);
    int liveRequests;
    /// Recognizes one live window with the same verified, warm worker as the
    /// final pass. Returns null when canceled; the final pass waits for the
    /// lock, so a live window can never run alongside or after it unnoticed.
    /// A worker that fails here is ended, so the final pass starts a fresh one.
    /// `started` runs once the window has the worker (after any wait for the lock, e.g. behind a launch
    /// prewarm), so the caller's speed judgement and time limit cover the recognition only.
    internal async Task<IReadOnlyList<WhisperWindowSegment>?> RecognizeLive(LiveWindowRequest request, string language, CancellationToken cancel, Action? started = null)
    {
        using (var waiting = CancellationTokenSource.CreateLinkedTokenSource(cancel, lifetime.Token)) {
            try { await modelLock.WaitAsync(waiting.Token); } catch (OperationCanceledException) { return null; }
        }
        bool answered = false;
        try {
            if (cancel.IsCancellationRequested) return null;
            if (!File.Exists(Executable)) throw new FileNotFoundException("The Windows speech engine is missing. Install a complete pFlow package.");
            await EnsureWorker(lifetime.Token);
            started?.Invoke();
            Interlocked.Increment(ref liveRequests);
            // The recognizer cancels a window after LiveSession.WindowLimitMs and the worker answers a
            // cancel within milliseconds; 30 s without any reply means the worker is stuck.
            var response = await worker!.RecognizeLive(request, language, TimeSpan.FromSeconds(30), cancel);
            answered = true;
            if (response.Segments != null) return response.Segments;
            if (cancel.IsCancellationRequested) return null;
            throw new IOException(response.Error ?? "Live recognition failed.");
        } catch when (!answered) { ResetWorker(); throw; }
        finally { modelLock.Release(); }
    }
    /// Ends a stuck worker without waiting for the lock; the next request starts a new one.
    internal void EndWorker() => worker?.Abort();
    internal void Abort() { lifetime.Cancel(); worker?.Abort(); }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); await modelLock.WaitAsync();
        try { ResetWorker(); } finally { modelLock.Release(); }
    }
}
