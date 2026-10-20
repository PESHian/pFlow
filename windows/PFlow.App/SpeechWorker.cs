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
            await worker.Send(writer => { writer.Write(LiveWorkerProtocol.Hello); writer.Write(Math.Clamp(Environment.ProcessorCount - 1, 1, 8)); WriteText(writer, model, 32768); }, timeout.Token);
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
    internal async Task<(string Text, SpeechMetrics Metrics)> Transcribe(string audio, string language, string prompt, CancellationToken cancel)
    {
        using var kill = cancel.Register(Abort);
        await Send(writer => { writer.Write(0x31514650u); WriteText(writer, audio, 32768); WriteText(writer, language, 64); WriteText(writer, prompt, 8192); }, cancel);
        uint kind = await Number(cancel);
        if (kind == 3) throw new IOException(await Text(cancel));
        if (kind != 2) throw new IOException("The speech engine sent an invalid response.");
        string text = await Text(cancel);
        double recognition = await Metric(cancel), encode = await Metric(cancel), decode = await Metric(cancel);
        int context = checked((int)await Number(cancel)); cancel.ThrowIfCancellationRequested();
        return (text, new(false, 0, recognition, encode, decode, context));
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
