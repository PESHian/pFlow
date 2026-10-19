using System.Text.RegularExpressions;

namespace PFlow.Core;

public sealed record TemplateCommand(DictationTemplate Template, string Text)
{
    // Port of the Mac's explicit prefix command. A report mentioned inside a narration never switches templates.
    public static TemplateCommand? Parse(string source, IEnumerable<DictationTemplate> templates)
    {
        var matches = new List<(DictationTemplate Template, int End, bool Exact)>();
        foreach (var template in templates) foreach (var alias in new[] { template.Name }.Concat(template.VoiceTriggers ?? []).Distinct(StringComparer.OrdinalIgnoreCase)) {
            string phrase = string.Join(@"[\s\-\u2011\u2013\u2014]+", Regex.Split(alias.Trim(), @"[\s\-\u2011\u2013\u2014]+").Select(Regex.Escape));
            if (phrase.Length == 0) continue;
            string pattern = @"^\s*(?:(?:okay|ok|please)[,.:]?\s+)?(?:(?:write|format)\s+(?:this\s+)?(?:as\s+)?|use\s+|this\s+is\s+)(?:(?:a|an|the)\s+)?" + phrase + @"(?![\p{L}\p{N}_])(?:\s+template\b)?";
            var match = Regex.Match(source, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (match.Success) matches.Add((template, match.Length, alias == template.Name));
        }
        if (matches.Count == 0) return null;
        int end = matches.Max(x => x.End); var best = matches.Where(x => x.End == end).ToList();
        if (best.Any(x => x.Exact)) best = best.Where(x => x.Exact).ToList();
        if (best.Select(x => x.Template.Id).Distinct().Count() != 1) return null;
        string text = source[end..].Trim();
        if (text.Length > 0 && ".,:;!?…\u2014\u2013-".Contains(text[0])) {
            string rest = text[1..].TrimStart();
            bool number = rest.Length > 0 && (char.IsDigit(rest[0]) || rest.Length > 1 && ".,".Contains(rest[0]) && char.IsDigit(rest[1]));
            if (!(number && ".,\u2013-".Contains(text[0]))) text = text[1..].TrimStart();
        }
        return new(best[0].Template, text);
    }
}
