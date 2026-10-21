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
    /// One plain line for Settings: the architecture this copy runs as and which
    /// speech worker it uses, so a tester can say what their PC runs.
    public static string Describe(string processArchitecture, string chosenExecutable) => processArchitecture.ToUpperInvariant() switch {
        "X64" => chosenExecutable == Avx2 ? "x64, fast speech engine (AVX2)" : "x64, standard speech engine (no AVX2)",
        "ARM64" => "ARM64 speech engine",
        "X86" => "x86 (32-bit) speech engine",
        var other => other + " speech engine"
    };
}
