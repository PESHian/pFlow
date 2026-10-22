using System.Text.RegularExpressions;

namespace PFlow.Core;

public static class TextFidelity
{
    public static bool RequiresExactCleanup(string text) => Regex.IsMatch(text, @"[^\p{L}\p{M}\s.,]");
    /// Sentence punctuation an edit may add, move or drop. Any other symbol (quotes, signs,
    /// operators, currency, emoji) binds meaning to its neighbours and must stay where it was.
    const string SentencePunctuation = ".,;:!?";
    /// The words and the guarded symbols of a text, in order: a word is letters, digits and
    /// apostrophes; a sentence mark is guarded when it sits inside or in front of a number
    /// ("14:30", "1,000", "3.5", ".5"), where it is part of the value, not of the sentence.
    static string[] Atoms(string value)
    {
        var fillers = new HashSet<string>(["uh", "um", "uhm", "umm", "hmm", "uhhh"]);
        var atoms = new List<string>(); var word = new System.Text.StringBuilder();
        void EndWord() { if (word.Length > 0) { string w = word.ToString().ToLowerInvariant(); if (!fillers.Contains(w)) atoms.Add(w); word.Clear(); } }
        for (int i = 0; i < value.Length; i++) {
            char c = value[i] == '’' ? '\'' : value[i];
            if (char.IsLetterOrDigit(c) || c == '\'' || char.GetUnicodeCategory(c) is System.Globalization.UnicodeCategory.NonSpacingMark or System.Globalization.UnicodeCategory.SpacingCombiningMark) { word.Append(c); continue; }
            EndWord();
            if (char.IsWhiteSpace(c)) continue;
            bool nextDigit = i + 1 < value.Length && char.IsDigit(value[i + 1]), previousDigit = i > 0 && char.IsDigit(value[i - 1]);
            bool previousBlank = i == 0 || char.IsWhiteSpace(value[i - 1]);
            if (SentencePunctuation.Contains(c) && !(nextDigit && (previousDigit || previousBlank))) continue;
            atoms.Add(c.ToString());
        }
        EndWord(); return atoms.ToArray();
    }
    public static bool CleanupIsFaithful(string source, string result)
    {
        if (string.IsNullOrWhiteSpace(result)) return false;
        var protectedWords = new HashSet<string>(["no", "not", "never", "cannot", "without", "can't", "won't", "don't", "didn't", "wasn't", "isn't"]);
        var original = Atoms(source); var edited = Atoms(result);
        // Only punctuation/case, fillers and removal of adjacent repeated words are allowed.
        // Each run stays in order and cannot gain words or lose a negation; a number or a
        // guarded symbol is never collapsed ("five five" may be 55).
        int a = 0, b = 0;
        while (a < original.Length && b < edited.Length) {
            if (original[a] != edited[b]) return false;
            string word = original[a]; int sourceRun = 0, editedRun = 0;
            while (a < original.Length && original[a] == word) { a++; sourceRun++; }
            while (b < edited.Length && edited[b] == word) { b++; editedRun++; }
            bool exact = protectedWords.Contains(word) || word.Any(char.IsDigit) || !char.IsLetter(word[0]);
            if (editedRun > sourceRun || (exact && editedRun != sourceRun)) return false;
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
