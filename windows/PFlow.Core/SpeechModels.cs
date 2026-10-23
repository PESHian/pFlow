namespace PFlow.Core;

/// One speech model the person can choose for the finished text: a pinned file from the
/// whisper.cpp model repository (one revision, one checksum), its plain size and one line on what
/// it trades. `Bundled` is the one every package ships; the others are downloads.
public sealed record SpeechModel(string Id, string Title, string FileName, string Url, string Sha, long Bytes, bool Bundled, string Note);

/// The speech models offered in Settings, one rule for the app, the worker start and the checks.
/// The live-words model (LiveSpeechModel, base-q5_1) is separate and never chosen here. W025 measured
/// the candidates on the fictional speed fixtures (1229 words) against Whisper small, both on the
/// Mac-matched finished pass: small 2.03% of words wrong; large-v3-turbo q8_0 1.46% (ARM64 native)
/// / 1.22% (x64) at 2.6x / 4.1x small's time; medium q5_0 1.30% at 2.6x / 4.1x; large-v3-turbo
/// q5_0 1.22-1.30% at 3.7x / 5.4x, so it is left out (no gain over q8_0, slower). Full numbers
/// per take in the ledger.
public static class SpeechModels
{
    public const string Revision = "5359861c739e955e79d9a303bcbc70fb988958b1";
    static string Url(string file) => "https://huggingface.co/ggerganov/whisper.cpp/resolve/" + Revision + "/" + file;
    public static readonly SpeechModel Small = new("small", "Whisper small", "ggml-small.bin", Url("ggml-small.bin"),
        "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", 487601967, true, "Included. The fastest choice.");
    public static readonly SpeechModel Turbo = new("large-v3-turbo-q8_0", "Whisper large-v3-turbo", "ggml-large-v3-turbo-q8_0.bin", Url("ggml-large-v3-turbo-q8_0.bin"),
        "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", 874188075, false, "Slower (about 3x), fewer mistakes.");
    public static readonly SpeechModel Medium = new("medium-q5_0", "Whisper medium", "ggml-medium-q5_0.bin", Url("ggml-medium-q5_0.bin"),
        "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", 539212467, false, "Slower (about 3x), fewer mistakes.");
    public static readonly IReadOnlyList<SpeechModel> All = [Small, Turbo, Medium];
    /// The saved choice, or small for anything unknown (an older settings file, a removed model).
    public static SpeechModel Resolve(string? id) => All.FirstOrDefault(x => x.Id == id) ?? Small;
}
