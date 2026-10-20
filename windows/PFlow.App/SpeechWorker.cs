using System.Text;
using System.Security.Cryptography;

namespace PFlow.Windows;

internal readonly record struct SpeechMetrics(bool Reused, double InitializationMs, double RecognitionMs, double EncodeMs, double DecodeMs, int AudioContext);

// Anonymous pipes belong to this app and its child. There is no HTTP server or socket.
internal sealed class SpeechWorker : IDisposable
{
    readonly FileStream modelLease;
    readonly Process process;
    readonly Stream input, output;
    internal bool Exited => process.HasExited;
    internal int Id => process.Id;
    internal double LoadMs { get; private set; }
    SpeechWorker(FileStream lease, Process process)
    {
        modelLease = lease; this.process = process; input = process.StandardInput.BaseStream; output = process.StandardOutput.BaseStream;
        _ = Drain(process.StandardError.BaseStream);
    }
    static async Task Drain(Stream errors) { try { await errors.CopyToAsync(Stream.Null); } catch (IOException) { } catch (ObjectDisposedException) { } }
    /// Processors the thread counts are sized for; the speed harness lowers it (with a matching affinity mask) to stand in for a small computer.
    internal static int LogicalProcessors { get; set; } = Environment.ProcessorCount;
    internal static async Task<SpeechWorker> Start(string executable, string model, CancellationToken cancel)
    {
        // Keep the checked file open without write/delete sharing for the worker's entire life.
        var lease = new FileStream(model, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        SpeechWorker? worker = null;
        try {
            if (lease.Length != Whisper.ModelBytes) throw new InvalidDataException("The Whisper model has the wrong size. Download it again in Settings.");
            var digest = await SHA256.HashDataAsync(lease, cancel);
            if (!Convert.ToHexString(digest).Equals(Whisper.ModelSha, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The Whisper model checksum did not match. Download it again in Settings.");
            var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            worker = new(lease, Process.Start(info) ?? throw new IOException("The speech engine could not start."));
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel); timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var kill = timeout.Token.Register(worker.Abort);
            int finalThreads = SpeechThreads.Final(LogicalProcessors), liveThreads = SpeechThreads.Live(LogicalProcessors);
            await worker.Send(writer => { writer.Write(LiveWorkerProtocol.Hello); writer.Write(finalThreads); writer.Write(liveThreads); WriteText(writer, model, 32768); }, timeout.Token);
            uint kind = await worker.Number(timeout.Token);
            if (kind == 3) throw new IOException(await worker.Text(timeout.Token));
            if (kind != 1) throw new IOException("The speech engine sent an invalid response.");
            worker.LoadMs = await worker.Metric(timeout.Token);
            if (await worker.Number(timeout.Token) != LiveWorkerProtocol.Version) throw new IOException("The speech engine is from another pFlow version. Install a complete pFlow package.");
            timeout.Token.ThrowIfCancellationRequested(); return worker;
        } catch { if (worker != null) worker.Dispose(); else lease.Dispose(); throw; }
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
            throw new IOException(Stalled, error);
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
    public void Dispose() { Abort(); input.Dispose(); output.Dispose(); process.Dispose(); modelLease.Dispose(); }
}
