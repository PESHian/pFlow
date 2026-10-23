using PFlow.Core;

// Speech worker rules: thread counts and which worker build to run.
internal static class SpeechChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static void Run()
    {
        passed = 0;
        Check("Whisper small is the one speech model, pinned by size and SHA-256, named in Settings as included",
            SpeechModels.Small.FileName == "ggml-small.bin" && SpeechModels.Small.Bytes == 487601967 && SpeechModels.Small.Sha == "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
            && SpeechModels.SettingsLine == "Speech model: Whisper small (included)");
        Check("the retired speech models are exactly 0.1.25's two downloads, never small, the live model or the text model",
            SpeechModels.RetiredFiles.SequenceEqual(new[] { "ggml-large-v3-turbo-q8_0.bin", "ggml-medium-q5_0.bin" })
            && !SpeechModels.RetiredFiles.Contains(SpeechModels.Small.FileName) && !SpeechModels.RetiredFiles.Contains(LiveSpeechModel.FileName) && SpeechModels.RetiredFiles.All(f => f.EndsWith(".bin")));
        Check("Settings names the architecture and the speech engine in use", SpeechEngine.Describe("X64", SpeechEngine.Avx2) == "x64, fast speech engine (AVX2)"
            && SpeechEngine.Describe("X64", SpeechEngine.Baseline) == "x64, standard speech engine (no AVX2)" && SpeechEngine.Describe("Arm64", SpeechEngine.Baseline) == "ARM64 speech engine"
            && SpeechEngine.Describe("X86", SpeechEngine.Baseline) == "x86 (32-bit) speech engine");
        Check("Settings says when live words lack their fast model and run on the main one",
            SpeechEngine.Describe("ARM64", SpeechEngine.Baseline, liveModel: false) == "ARM64 speech engine, live words on the main model (slower; the live model file is missing or damaged)"
            && !SpeechEngine.Describe("ARM64", SpeechEngine.Baseline, liveModel: true).Contains("main model"));
        Check("the live model is the 5-bit base model, with its exact size and checksum pinned",
            LiveSpeechModel.FileName == "ggml-base-q5_1.bin" && LiveSpeechModel.Bytes == 59707625 && LiveSpeechModel.Sha.Length == 64 && LiveSpeechModel.Sha == LiveSpeechModel.Sha.ToLowerInvariant());
        { var hello = LiveWorkerProtocol.EncodeHello(7, 4, "C:\\m\\main.bin", "C:\\m\\live.bin"); var span = hello.AsSpan();
          string main = System.Text.Encoding.UTF8.GetString(span.Slice(16, 13)); string live = System.Text.Encoding.UTF8.GetString(span.Slice(33, 13));
          Check("the hello frame carries both thread counts, the main model and the live model, each length-prefixed",
              hello.Length == 16 + 13 + 4 + 13 && BitConverter.ToUInt32(hello, 0) == LiveWorkerProtocol.Hello && BitConverter.ToInt32(hello, 4) == 7 && BitConverter.ToInt32(hello, 8) == 4
              && BitConverter.ToUInt32(hello, 12) == 13 && main == "C:\\m\\main.bin" && BitConverter.ToUInt32(hello, 29) == 13 && live == "C:\\m\\live.bin");
          var alone = LiveWorkerProtocol.EncodeHello(7, 4, "C:\\m\\main.bin", null);
          Check("without a live model the hello sends an empty live path, so the worker keeps live windows on the main model", alone.Length == 16 + 13 + 4 && BitConverter.ToUInt32(alone, 29) == 0);
          Check("the live protocol version moved to 4 with the two-model hello", LiveWorkerProtocol.Version == 4); }
        Check("the finished-text pass keeps the 0.1.15 thread count: all but one logical processor, 1 to 8",
            SpeechThreads.Final(1) == 1 && SpeechThreads.Final(2) == 1 && SpeechThreads.Final(4) == 3 && SpeechThreads.Final(8) == 7 && SpeechThreads.Final(24) == 8);
        Check("live windows get half the logical processors, 1 to 4",
            SpeechThreads.Live(1) == 1 && SpeechThreads.Live(2) == 1 && SpeechThreads.Live(4) == 2 && SpeechThreads.Live(6) == 3 && SpeechThreads.Live(8) == 4 && SpeechThreads.Live(32) == 4);
        Check("live never uses more threads than the final pass on any machine",
            Enumerable.Range(1, 64).All(cores => SpeechThreads.Live(cores) <= SpeechThreads.Final(cores)));
        Check("the AVX2 worker runs only in an x64 process on a processor with AVX2, FMA, F16C and BMI2, and only when it is present",
            SpeechEngine.Choose(true, true, _ => true) == "pflow-whisper-avx2.exe"
            && SpeechEngine.Choose(true, false, _ => true) == "pflow-whisper.exe"
            && SpeechEngine.Choose(false, true, _ => true) == "pflow-whisper.exe"
            && SpeechEngine.Choose(true, true, name => name == "pflow-whisper.exe") == "pflow-whisper.exe");
        Console.WriteLine($"{passed} speech worker checks passed.");
    }
}
