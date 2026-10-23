using System.Globalization;
using System.Text.Json;

namespace PFlow.Windows;

// Read only the existing numeric record. Never read transcripts or app names.
internal static class ProcessingTimes
{
    /// The stages named on the line. A record from before W025 may carry cleanupMs and cleanupOutcome
    /// from the removed AI cleanup; they are left out.
    static readonly (string Key, string Label)[] Stages = [("recognitionMs", "Speech"), ("reportMs", "Report"), ("insertionMs", "Insertion")];
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
            foreach (var (key, label) in Stages) if (Number(key) is { } ms) stages.Add(label + ": " + Seconds(ms));
            return "Last dictation: " + Seconds(total) + (stages.Count == 0 ? "." : ".\n" + string.Join(" · ", stages));
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or FormatException) {
            return "Processing time is unavailable.";
        }
    }
}
