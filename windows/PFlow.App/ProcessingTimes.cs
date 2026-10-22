using System.Globalization;
using System.Text.Json;

namespace PFlow.Windows;

// Read only the existing numeric record. Never read transcripts or app names.
internal static class ProcessingTimes
{
    /// The cleanup number alone cannot say whether the words changed; this does.
    static string Outcome(double? code) => code switch {
        (double)CleanupOutcome.Applied => " (used)", (double)CleanupOutcome.Rejected => " (changed the words, so not used)",
        (double)CleanupOutcome.TimedOut => " (took too long, not used)", (double)CleanupOutcome.Failed => " (engine failed, not used)",
        (double)CleanupOutcome.Skipped => " (nothing to clean)", (double)CleanupOutcome.Partial => " (partly used)",
        (double)CleanupOutcome.RejectedSymbols => " (changed punctuation inside a number, so not used)", _ => "" };
    public static string Read(string directory)
    {
        string file = Path.Combine(directory, "last-processing-times.json");
        try {
            if (!File.Exists(file)) return "Processing time appears here after your next dictation.";
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > 16384) return "Processing time is unavailable.";
            using var json = JsonDocument.Parse(stream);
            double? Number(string name) => json.RootElement.TryGetProperty(name, out var value) && value.TryGetDouble(out double number) && double.IsFinite(number) && number >= 0 ? number : null;
            string Seconds(double ms) => (ms / 1000).ToString("0.0", CultureInfo.CurrentCulture) + " s";
            if (Number("totalAfterReleaseMs") is not { } total) return "Processing time is unavailable.";
            var stages = new List<string>();
            foreach (var (key, label) in new[] { ("recognitionMs", "Speech"), ("cleanupMs", "AI cleanup"), ("reportMs", "Report"), ("insertionMs", "Insertion") })
                if (Number(key) is { } ms) stages.Add(label + ": " + Seconds(ms) + (key == "cleanupMs" ? Outcome(Number("cleanupOutcome")) : ""));
            if (Number("cleanupMs") == null && Number("cleanupOutcome") == (double)CleanupOutcome.NotRun) stages.Add("AI cleanup: not run (model not installed)");
            if (Number("cleanupMs") == null && Number("cleanupOutcome") == (double)CleanupOutcome.LocalAIOff) stages.Add("AI cleanup: not run (local text model off)");
            return "Last dictation: " + Seconds(total) + (stages.Count == 0 ? "." : ".\n" + string.Join(" · ", stages));
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or FormatException) {
            return "Processing time is unavailable.";
        }
    }
}
