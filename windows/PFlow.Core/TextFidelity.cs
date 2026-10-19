using System.Text.RegularExpressions;

namespace PFlow.Core;

public static class TextFidelity
{
    static string[] Tokens(string text, string pattern) => Regex.Matches(text, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant).Select(m => m.Value.ToLowerInvariant()).ToArray();
    public static bool RequiresExactCleanup(string text) => Regex.IsMatch(text, @"[^\p{L}\p{M}\s.,]");
    public static bool CleanupIsFaithful(string source, string result)
    {
        if (string.IsNullOrWhiteSpace(result)) return false;
        // Keep risky blocks exactly: punctuation can bind a value or quote to a particular word.
        if (RequiresExactCleanup(source) || RequiresExactCleanup(result)) return string.Equals(source, result, StringComparison.Ordinal);
        var fillers = new HashSet<string>(["uh", "um", "uhm", "umm", "hmm", "uhhh"]);
        var protectedWords = new HashSet<string>(["no", "not", "never", "cannot", "without", "can't", "won't", "don't", "didn't", "wasn't", "isn't"]);
        string[] Words(string value) => Tokens(value.Replace('’', '\''), @"[\p{L}\p{M}\p{N}']+").Where(x => !fillers.Contains(x)).ToArray();
        var original = Words(source); var edited = Words(result);
        // Only punctuation/case, fillers and removal of adjacent repeats are allowed.
        // Each run stays in order and cannot gain words or lose a negation.
        int a = 0, b = 0;
        while (a < original.Length && b < edited.Length) {
            if (original[a] != edited[b]) return false;
            string word = original[a]; int sourceRun = 0, editedRun = 0;
            while (a < original.Length && original[a] == word) { a++; sourceRun++; }
            while (b < edited.Length && edited[b] == word) { b++; editedRun++; }
            if (editedRun > sourceRun || (protectedWords.Contains(word) && editedRun != sourceRun)) return false;
        }
        if (a != original.Length || b != edited.Length) return false;
        if (Regex.Matches(source, @"\n\s*\n").Count > 0 && Regex.Matches(result, @"\n\s*\n").Count != Regex.Matches(source, @"\n\s*\n").Count) return false;
        return true;
    }
    public static List<string> Sentences(string source) => Regex.Split(source.Trim(), @"(?<=[.!?])[ \t\r\n]+(?=[\p{Lu}\p{N}])").Where(x => x.Length > 0).ToList();
    public static List<List<string>> Batches(IEnumerable<string> sentences, int limit = 3500)
    {
        var result = new List<List<string>>(); var batch = new List<string>(); int length = 0;
        foreach (var sentence in sentences) {
            if (batch.Count > 0 && length + sentence.Length > limit) { result.Add(batch); batch = []; length = 0; }
            batch.Add(sentence); length += sentence.Length;
        }
        if (batch.Count > 0) result.Add(batch); return result;
    }
}
