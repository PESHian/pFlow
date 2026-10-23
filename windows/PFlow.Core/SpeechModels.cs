namespace PFlow.Core;

/// The speech model for the finished text: one pinned file from the whisper.cpp model repository.
public sealed record SpeechModel(string Title, string FileName, string Sha, long Bytes);

/// Whisper small is the one speech model; every package ships it. The live-words model
/// (LiveSpeechModel, base-q5_1) is separate.
public static class SpeechModels
{
    public static readonly SpeechModel Small = new("Whisper small", "ggml-small.bin", "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", 487601967);
    /// For Settings, where the speech model is named.
    public static readonly string SettingsLine = "Speech model: " + Small.Title + " (included)";
    /// The downloads 0.1.25 offered next to small (large-v3-turbo q8_0 and medium q5_0), removed in
    /// 0.1.26: 3-4 times small's time per take on the owner's PC. At start pFlow deletes these exact
    /// files from its own folder, with their unfinished downloads, and nothing else. A saved choice of
    /// either (settings key speechModel) is no longer read: every take runs on small.
    public static readonly IReadOnlyList<string> RetiredFiles = ["ggml-large-v3-turbo-q8_0.bin", "ggml-medium-q5_0.bin"];
}
