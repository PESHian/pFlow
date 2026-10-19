using System.Net.Http;
using System.Security.Cryptography;

namespace PFlow.Windows;

internal sealed class Whisper : IAsyncDisposable
{
    public const string ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin";
    public const string ModelSha = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b";
    public const long ModelBytes = 487601967;
    readonly string root;
    readonly string assets;
    readonly SemaphoreSlim modelLock = new(1);
    readonly CancellationTokenSource lifetime = new();
    SpeechWorker? worker;
    internal SpeechMetrics LastMetrics { get; private set; }
    internal int? WorkerId => worker?.Id;
    string DownloadPath => System.IO.Path.Combine(root, "ggml-small.bin");
    public string ModelPath => File.Exists(DownloadPath) ? DownloadPath : System.IO.Path.Combine(assets, "models", "ggml-small.bin");
    public string Executable => System.IO.Path.Combine(assets, "engine", "pflow-whisper.exe");
    public bool FilesPresent => File.Exists(ModelPath) && File.Exists(Executable);
    public Whisper(string root, string? assetsRoot = null) { this.root = root; assets = assetsRoot ?? AppContext.BaseDirectory; }
    public async Task Verify(string path, CancellationToken cancel)
    {
        if (new FileInfo(path).Length != ModelBytes) throw new InvalidDataException("The Whisper model has the wrong size. Download it again in Settings.");
        await using var stream = File.OpenRead(path);
        var digest = await SHA256.HashDataAsync(stream, cancel);
        if (!Convert.ToHexString(digest).Equals(ModelSha, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The Whisper model checksum did not match. Download it again in Settings.");
    }
    public async Task Download(IProgress<double> progress, CancellationToken cancel)
    {
        await modelLock.WaitAsync(cancel); string temp = DownloadPath + "." + Guid.NewGuid() + ".download";
        try {
            using var client = new HttpClient { Timeout = TimeSpan.FromHours(1) };
            using var response = await client.GetAsync(ModelUrl, HttpCompletionOption.ResponseHeadersRead, cancel); response.EnsureSuccessStatusCode();
            await using (var source = await response.Content.ReadAsStreamAsync(cancel))
            await using (var target = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                var bytes = new byte[1024 * 1024]; long total = 0; int count;
                while ((count = await source.ReadAsync(bytes, cancel)) > 0) {
                    total += count; if (total > ModelBytes) throw new InvalidDataException("Model download was larger than expected.");
                    await target.WriteAsync(bytes.AsMemory(0, count), cancel); progress.Report((double)total / ModelBytes);
                }
            }
            await Verify(temp, cancel); ResetWorker(); File.Move(temp, DownloadPath, true);
        } finally { if (File.Exists(temp)) File.Delete(temp); modelLock.Release(); }
    }
    void ResetWorker() { worker?.Dispose(); worker = null; }
    async Task EnsureWorker(CancellationToken cancel)
    {
        if (worker != null && !worker.Exited) return;
        ResetWorker(); worker = await SpeechWorker.Start(Executable, ModelPath, cancel);
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
            bool reused = worker != null && !worker.Exited; var watch = Stopwatch.StartNew();
            LastMetrics = default; await EnsureWorker(cancel); double initialization = watch.Elapsed.TotalMilliseconds;
            var terms = string.Join(", ", vocabulary.Where(x => !string.IsNullOrWhiteSpace(x))).Trim();
            var result = await worker!.Transcribe(audio, language, terms[..Math.Min(terms.Length, 2000)], cancel);
            LastMetrics = result.Metrics with { Reused = reused, InitializationMs = initialization };
            string text = result.Text.Trim();
            if (string.IsNullOrWhiteSpace(text)) throw new IOException("No speech was found. Check the microphone and try again.");
            return TextProcessing.JoinRecognitionLines(text);
        } catch when (cancel.IsCancellationRequested) { ResetWorker(); throw new OperationCanceledException(cancel); }
        catch { ResetWorker(); throw; }
        finally { modelLock.Release(); }
    }
    internal void Abort() { lifetime.Cancel(); worker?.Abort(); }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); await modelLock.WaitAsync();
        try { ResetWorker(); } finally { modelLock.Release(); }
    }
}
