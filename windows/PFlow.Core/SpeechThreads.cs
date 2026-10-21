namespace PFlow.Core;

/// How many processor threads the speech worker uses. The finished-text pass
/// keeps the count 0.1.15 shipped with. Live windows get at most half the
/// logical processors (never more than four), so the final pass, the recorder
/// and the rest of the computer always have room while someone is speaking.
public static class SpeechThreads
{
    public static int Final(int logicalProcessors) => Math.Clamp(logicalProcessors - 1, 1, 8);
    public static int Live(int logicalProcessors) => Math.Clamp(logicalProcessors / 2, 1, 4);
}

/// Which speech worker to run. The baseline build uses no instruction newer
/// than SSE2 and runs on any processor; on x64 that makes it 11-13 times slower
/// than the AVX2 build (measured on the same source and model). The AVX2 build
/// is chosen only when the processor and Windows report AVX2, FMA, F16C and BMI2
/// and the file is present, so an older processor still gets working dictation.
public static class SpeechEngine
{
    public const string Baseline = "pflow-whisper.exe", Avx2 = "pflow-whisper-avx2.exe";
    public static string Choose(bool x64Process, bool avx2Ready, Func<string, bool> present) =>
        x64Process && avx2Ready && present(Avx2) ? Avx2 : Baseline;
    /// One plain line for Settings: the architecture this copy runs as, which
    /// speech worker it uses, and whether live words have their fast model, so
    /// a tester can say what their PC runs.
    public static string Describe(string processArchitecture, string chosenExecutable, bool liveModel = true) => (processArchitecture.ToUpperInvariant() switch {
        "X64" => chosenExecutable == Avx2 ? "x64, fast speech engine (AVX2)" : "x64, standard speech engine (no AVX2)",
        "ARM64" => "ARM64 speech engine",
        "X86" => "x86 (32-bit) speech engine",
        var other => other + " speech engine"
    }) + (liveModel ? "" : ", live words on the main model (slower; the live model file is missing)");
}

/// The small, fast Whisper model used only for live words while someone
/// speaks (base, 5-bit). The finished text always comes from the main model,
/// so this model never changes what is typed. It is installed next to the
/// main model; without it, live windows run on the main model and Settings
/// says so.
public static class LiveSpeechModel
{
    public const string FileName = "ggml-base-q5_1.bin";
    public const string Sha = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898";
    public const long Bytes = 59707625;
}
