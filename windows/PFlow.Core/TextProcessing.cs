using System.Text.RegularExpressions;

namespace PFlow.Core;

public static class TextProcessing
{
    public static bool SameText(string left, string right) => left.Replace("\r\n", "\n").Replace('\r', '\n') == right.Replace("\r\n", "\n").Replace('\r', '\n');
    public static int WordCount(string text) => Regex.Matches(text, @"\S+").Count;
    public static string Replace(string text, IEnumerable<DictionaryEntry> entries)
    {
        var rules = entries.Where(x => !string.IsNullOrWhiteSpace(x.Heard) && !string.IsNullOrWhiteSpace(x.Replacement))
            .OrderByDescending(x => x.Heard.Length).GroupBy(x => x.Heard.Trim(), StringComparer.OrdinalIgnoreCase).Select(x => x.First()).ToList();
        if (rules.Count == 0) return text;
        var patterns = rules.Select(x => string.Join(@"\s+", Regex.Split(x.Heard.Trim(), @"\s+").Select(Regex.Escape))).ToList();
        var expression = @"(?<![\p{L}\p{N}_])(?:" + string.Join("|", patterns.Select((p, i) => $"(?<r{i}>{p})")) + @")(?![\p{L}\p{N}_])";
        return Regex.Replace(text, expression, match => {
            for (int i = 0; i < rules.Count; i++) if (match.Groups[$"r{i}"].Success) return rules[i].Replacement;
            return match.Value;
        }, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(2));
    }
    public static bool SupportsEnglishCleanup(string language) => language.Equals("en", StringComparison.OrdinalIgnoreCase) || language.Equals("english", StringComparison.OrdinalIgnoreCase);
    // These filler and fidelity rules are English only; preserve other languages.
    public static string RemoveFillers(string text, IEnumerable<string> vocabulary, string language = "en")
    {
        if (!SupportsEnglishCleanup(language)) return text;
        var protectedWords = vocabulary.Where(x => !string.IsNullOrWhiteSpace(x)).SelectMany(x => Regex.Matches(x, @"[\p{L}\p{M}]+").Select(m => m.Value)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var parts = Regex.Split(text, @"(\r?\n[ \t]*\r?\n)");
        for (int i = 0; i < parts.Length; i += 2) {
            string original = parts[i];
            if (TextFidelity.RequiresExactCleanup(original)) continue;
            string cleaned = Regex.Replace(original, @"\b(?:uhhh|uhm|umm|hmm|uh|um)\b,?", match =>
                protectedWords.Contains(match.Value.TrimEnd(',')) ? match.Value : "", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (cleaned == original) continue;
            cleaned = Regex.Replace(cleaned, @"[ \t]{2,}", " ");
            cleaned = Regex.Replace(cleaned, @",\s*,", ",");
            cleaned = Regex.Replace(cleaned, @"[ \t]+([,.])", "$1").Trim().TrimStart(',').TrimStart();
            cleaned = Regex.Replace(cleaned, @",[ \t]*[.]", ".");
            cleaned = Regex.Replace(cleaned, @"(^|[.]\s+)([\p{L}\p{M}]+)", match => {
                string word = match.Groups[2].Value;
                return match.Groups[1].Value + (word.Any(char.IsUpper) ? word : char.ToUpperInvariant(word[0]) + word[1..]);
            });
            if (Regex.IsMatch(cleaned, @"[\p{L}\p{N}]") && TextFidelity.CleanupIsFaithful(original, cleaned)) parts[i] = cleaned;
        }
        return string.Concat(parts);
    }
    // Whisper text output wraps recognition segments; these are soft boundaries, not paragraphs.
    public static string JoinRecognitionLines(string text)
    {
        text = text.Replace("\r\n", "\n");
        if (Regex.IsMatch(text, @"(?m)^[ \t]*(?:[-*•]|\d+[.)]|#{1,6}|```)[ \t]+")) return text;
        return Regex.Replace(text, @"(?<!\n)\n(?!\n)", " ");
    }
    // Conservative port of DictationParagraphs: change whitespace only, between complete sentences.
    public static string Paragraphs(string text)
    {
        return string.Join("\n\n", text.Replace("\r\n", "\n").Split("\n\n").Select(block => {
            if (block.Contains('\n') || WordCount(block) <= 110 || Regex.IsMatch(block, @"^\s*(?:[-*•]|\d+[.)]|#{1,6}|```)[ \t]+")) return block;
            var starts = new List<int> { 0 };
            foreach (Match m in Regex.Matches(block, @"(?<=[.!?])[""’”\')\]]*[ \t]+(?=[\p{Lu}\p{N}])")) {
                var prior = block[..m.Index];
                if (Regex.IsMatch(prior, @"\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\.$", RegexOptions.IgnoreCase)) continue;
                starts.Add(m.Index + m.Length);
            }
            var breaks = new List<int>(); int count = 0, words = 0;
            for (int i = 0; i < starts.Count; i++) {
                var sentence = block[starts[i]..(i + 1 < starts.Count ? starts[i + 1] : block.Length)];
                bool topic = Regex.IsMatch(sentence, @"^(?:Separately,|Regarding |Turning to |As for |Meanwhile,|The next day|Later that )", RegexOptions.IgnoreCase);
                if (count >= 2 && (topic || ((count >= 2 && words >= 75 || count >= 4 && words >= 45) && i < starts.Count - 1))) {
                    breaks.Add(starts[i]); count = words = 0;
                }
                count++; words += WordCount(sentence);
            }
            foreach (int end in breaks.AsEnumerable().Reverse()) {
                int begin = end; while (begin > 0 && char.IsWhiteSpace(block[begin - 1])) begin--;
                block = block[..begin] + "\n\n" + block[end..];
            }
            return block;
        }));
    }
    public static string RenderFullNarrative(string source, DictationTemplate template)
    {
        return RichText.Render(source, template).Text;
    }
}
