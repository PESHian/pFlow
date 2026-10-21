using System.Text;
using System.Security.Cryptography;

namespace PFlow.Windows;

internal readonly record struct SpeechMetrics(bool Reused, double InitializationMs, double RecognitionMs, double EncodeMs, double DecodeMs, int AudioContext);

/// The worker process was lost or went quiet (start, model load or a pass without progress).
/// Not a worker-reported error: a fresh worker may well succeed, so the caller retries once.
internal sealed class SpeechWorkerLost(string message, Exception? inner = null) : IOException(message, inner);

// Anonymous pipes belong to this app and its child. There is no HTTP server or socket.
internal sealed class SpeechWorker : IDisposable
{
    readonly FileStream modelLease;
    readonly FileStream? liveModelLease;
    readonly Process process;
    readonly Stream input, output;
    internal bool Exited => process.HasExited;
    internal int Id => process.Id;
    internal double LoadMs { get; private set; }
    /// True when this worker runs live windows on the small live model.
    internal bool LiveModelLoaded => liveModelLease != null;
    SpeechWorker(FileStream lease, FileStream? liveLease, Process process)
    {
        modelLease = lease; liveModelLease = liveLease; this.process = process; input = process.StandardInput.BaseStream; output = process.StandardOutput.BaseStream;
        _ = Drain(process.StandardError.BaseStream);
    }
    static async Task Drain(Stream errors) { try { await errors.CopyToAsync(Stream.Null); } catch (IOException) { } catch (ObjectDisposedException) { } }
    /// Processors the thread counts are sized for; the speed harness lowers it (with a matching affinity mask) to stand in for a small computer.
    internal static int LogicalProcessors { get; set; } = Environment.ProcessorCount;
    /// Test hooks: a delay per 1 MB hashed (a slow disk), and starts to fail outright (a worker that dies at launch).
    internal static Func<Task>? StartThrottle { get; set; }
    internal static int FailNextStarts { get; set; }
    /// Progress frames received while the last worker loaded its model.
    internal int StartHeartbeats { get; private set; }
    /// Starting has no fixed time limit: hashing the 487 MB model and loading it both report progress
    /// (a chunk hashed, a frame from the worker), and only `StallLimit` without any progress ends it. A slow
    /// disk or a virus scanner reading the file makes a start slow, not stuck. `liveModel` (null when the
    /// file is not installed) is checked the same way; a present but damaged live model stops the start,
    /// like a damaged main model, instead of quietly running live words on the main model.
    internal static async Task<SpeechWorker> Start(string executable, string model, string? liveModel, CancellationToken cancel)
    {
        if (FailNextStarts > 0) { FailNextStarts--; throw new SpeechWorkerLost(Stalled); }
        // Keep the checked files open without write/delete sharing for the worker's entire life.
        var lease = Lease(model); FileStream? liveLease = null;
        SpeechWorker? worker = null;
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancel); stall.CancelAfter(StallLimit);
        var token = stall.Token;
        try {
            await Verify(lease, Whisper.ModelBytes, Whisper.ModelSha, "The Whisper model", "Download it again in Settings.", stall, token);
            if (liveModel != null) {
                liveLease = Lease(liveModel);
                await Verify(liveLease, LiveSpeechModel.Bytes, LiveSpeechModel.Sha, "The live speech model", "Install a complete pFlow package.", stall, token);
            }
            var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            worker = new(lease, liveLease, Process.Start(info) ?? throw new SpeechWorkerLost("The speech engine could not start."));
            using var kill = token.Register(worker.Abort);
            int finalThreads = SpeechThreads.Final(LogicalProcessors), liveThreads = SpeechThreads.Live(LogicalProcessors);
            await worker.Write(LiveWorkerProtocol.EncodeHello(finalThreads, liveThreads, model, liveModel), token);
            uint kind;
            while ((kind = await worker.Number(token)) == LiveWorkerProtocol.Progress) { worker.StartHeartbeats++; stall.CancelAfter(StallLimit); }
            if (kind == 3) throw new IOException(await worker.Text(token));
            if (kind != 1) throw new IOException("The speech engine sent an invalid response.");
            worker.LoadMs = await worker.Metric(token);
            if (await worker.Number(token) != LiveWorkerProtocol.Version) throw new IOException("The speech engine is from another pFlow version. Install a complete pFlow package.");
            token.ThrowIfCancellationRequested(); return worker;
        } catch (Exception error) when (error is OperationCanceledException or IOException && token.IsCancellationRequested && !cancel.IsCancellationRequested) {
            if (worker != null) worker.Dispose(); else { lease.Dispose(); liveLease?.Dispose(); }
            throw new SpeechWorkerLost(Stalled, error);
        } catch { if (worker != null) worker.Dispose(); else { lease.Dispose(); liveLease?.Dispose(); } throw; }
    }
    static FileStream Lease(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
    /// Size and SHA-256 of a model file, chunk by chunk; each chunk resets the stall limit.
    static async Task Verify(FileStream file, long bytes, string sha, string name, string remedy, CancellationTokenSource stall, CancellationToken token)
    {
        if (file.Length != bytes) throw new InvalidDataException(name + " has the wrong size. " + remedy);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var chunk = new byte[1024 * 1024]; int count;
        while ((count = await file.ReadAsync(chunk, token)) > 0) {
            hash.AppendData(chunk, 0, count); stall.CancelAfter(StallLimit);
            if (StartThrottle != null) await StartThrottle();
        }
        if (!Convert.ToHexString(hash.GetHashAndReset()).Equals(sha, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException(name + " checksum did not match. " + remedy);
    }
    static void WriteText(BinaryWriter writer, string value, int maximum)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > maximum || value.Contains('\0')) throw new InvalidDataException("A speech setting is too long or invalid.");
        writer.Write(bytes.Length); writer.Write(bytes);
    }
    async Task Send(Action<BinaryWriter> prepare, CancellationToken cancel)
    {
        using var data = new MemoryStream(); using (var writer = new BinaryWriter(data, Encoding.UTF8, true)) prepare(writer);
        await Write(data.GetBuffer().AsMemory(0, (int)data.Length), cancel);
    }
    // A late cancel frame must never land inside another request's bytes.
    readonly SemaphoreSlim writing = new(1);
    async Task Write(ReadOnlyMemory<byte> data, CancellationToken cancel)
    {
        await writing.WaitAsync(cancel);
        try { await input.WriteAsync(data, cancel); await input.FlushAsync(cancel); } finally { writing.Release(); }
    }
    async Task<byte[]> Read(int size, CancellationToken cancel) { var bytes = new byte[size]; await output.ReadExactlyAsync(bytes, cancel); return bytes; }
    async Task<uint> Number(CancellationToken cancel) => BitConverter.ToUInt32(await Read(4, cancel));
    async Task<double> Metric(CancellationToken cancel) => BitConverter.ToDouble(await Read(8, cancel));
    async Task<string> Text(CancellationToken cancel)
    {
        uint size = await Number(cancel); if (size > 2 * 1024 * 1024) throw new IOException("The speech engine sent an invalid result.");
        return new UTF8Encoding(false, true).GetString(await Read((int)size, cancel));
    }
    /// How long the finished-text pass may go without a progress frame before
    /// the worker counts as stuck. The worker sends one about every second
    /// while whisper computes, so a slow processor is never mistaken for a
    /// stuck one; the pass as a whole has no fixed time limit here.
    internal static TimeSpan StallLimit { get; set; } = TimeSpan.FromSeconds(60);
    internal const string Stalled = "The speech engine stopped answering. Try again.";
    /// Progress frames received during finished-text passes.
    internal int Heartbeats { get; private set; }
    internal async Task<(string Text, SpeechMetrics Metrics)> Transcribe(string audio, string language, string prompt, CancellationToken cancel)
    {
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancel); stall.CancelAfter(StallLimit);
        var token = stall.Token;
        using var kill = token.Register(Abort);
        try {
            await Send(writer => { writer.Write(0x31514650u); WriteText(writer, audio, 32768); WriteText(writer, language, 64); WriteText(writer, prompt, 8192); }, token);
            uint kind;
            while ((kind = await Number(token)) == LiveWorkerProtocol.Progress) { Heartbeats++; stall.CancelAfter(StallLimit); }
            if (kind == 3) throw new IOException(await Text(token));
            if (kind != 2) throw new IOException("The speech engine sent an invalid response.");
            string text = await Text(token);
            double recognition = await Metric(token), encode = await Metric(token), decode = await Metric(token);
            int context = checked((int)await Number(token)); token.ThrowIfCancellationRequested();
            return (text, new(false, 0, recognition, encode, decode, context));
        } catch (Exception error) when (error is OperationCanceledException or IOException && token.IsCancellationRequested && !cancel.IsCancellationRequested) {
            throw new SpeechWorkerLost(Stalled, error);
        } catch (Exception error) when (error is EndOfStreamException or IOException && error is not SpeechWorkerLost && !cancel.IsCancellationRequested && process.HasExited) {
            // The worker died under the pass (crash, out of memory): not a worker-reported error, so a fresh worker gets one try.
            throw new SpeechWorkerLost("The speech engine stopped unexpectedly. Try again.", error);
        }
    }
    /// One live window. A cancel asks the worker to stop this window and still
    /// waits for its reply, so the pipe stays in step and the warm model is kept.
    /// The reply has a hard deadline; a worker that misses it is ended.
    internal async Task<LiveWorkerProtocol.Response> RecognizeLive(LiveWindowRequest request, string language, TimeSpan limit, CancellationToken cancel)
    {
        byte[] frame = LiveWorkerProtocol.EncodeRequest(request.Session, request.Sequence, language, request.Samples);
        using var deadline = new CancellationTokenSource(limit);
        using var kill = deadline.Token.Register(Abort);
        await Write(frame, deadline.Token);
        byte[] stop = LiveWorkerProtocol.EncodeCancel(request.Session, request.Sequence);
        int cancelSent = 0;
        void SendCancel() { if (Interlocked.Exchange(ref cancelSent, 1) == 0) _ = Task.Run(async () => { try { await Write(stop, CancellationToken.None); } catch (IOException) { } catch (ObjectDisposedException) { } }); }
        using var canceled = cancel.Register(SendCancel);
        var (response, discarded) = await LiveWorkerProtocol.ReadReply(output, request.Session, request.Sequence, deadline.Token);
        StaleLiveReplies += discarded;
        return response;
    }
    internal int StaleLiveReplies { get; private set; }
    internal void Abort() { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } }
    public void Dispose() { Abort(); input.Dispose(); output.Dispose(); process.Dispose(); modelLease.Dispose(); liveModelLease?.Dispose(); }
}
