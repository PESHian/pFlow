using PFlow.Core;

// Speech worker rules: thread counts and which worker build to run.
internal static class SpeechChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static void Run()
    {
        passed = 0;
        Check("Settings names the architecture and the speech engine in use", SpeechEngine.Describe("X64", SpeechEngine.Avx2) == "x64, fast speech engine (AVX2)"
            && SpeechEngine.Describe("X64", SpeechEngine.Baseline) == "x64, standard speech engine (no AVX2)" && SpeechEngine.Describe("Arm64", SpeechEngine.Baseline) == "ARM64 speech engine"
            && SpeechEngine.Describe("X86", SpeechEngine.Baseline) == "x86 (32-bit) speech engine");
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
