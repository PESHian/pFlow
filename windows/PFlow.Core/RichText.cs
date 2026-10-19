using System.Text;

namespace PFlow.Core;

public static class RichText
{
    public static string? Pad(string rtf, string before, string after)
    {
        if (before.Length == 0 && after.Length == 0) return rtf;
        int body = rtf.IndexOf(@"\uc1 ", StringComparison.Ordinal);
        if (body < 0 || !rtf.StartsWith(@"{\rtf1", StringComparison.Ordinal) || !rtf.EndsWith('}')) return null;
        body += 5;
        return rtf[..body] + @"\b0 " + before + rtf[body..^1] + @"\b0 " + after + "}";
    }
    public static (string Text, string? Rtf) Render(string source, DictationTemplate template)
    {
        if (template.NeedsAI) throw new InvalidOperationException("This template needs an unavailable text model. Your dictation was kept.");
        return RenderSections(source, template, []);
    }
    public static (string Text, string? Rtf) RenderSections(string source, DictationTemplate template, IReadOnlyList<string> bodies)
    {
        var ranges = new List<(int Start, int Length)>(); var plain = new StringBuilder();
        void Heading(string title) {
            if (plain.Length > 0) plain.Append("\n\n");
            ranges.Add((plain.Length, title.Length)); plain.Append(title);
        }
        if (!string.IsNullOrWhiteSpace(template.Title)) Heading(template.Title);
        for (int index = 0; index < template.Sections.Count; index++) {
            var section = template.Sections[index];
            Heading(template.HeadingStyle switch { "uppercase" => section.Title.ToUpperInvariant(), "markdown" => "## " + section.Title, _ => section.Title });
            string body = section.IncludeFullDictation == true ? source : index < bodies.Count ? bodies[index] : "";
            plain.Append('\n').Append(string.IsNullOrWhiteSpace(body) ? template.MissingText : body);
        }
        string text = plain.ToString();
        if (template.BoldHeadings != true) return (text, null);
        var output = new StringBuilder(@"{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\uc1 ");
        for (int i = 0; i < text.Length; i++) {
            if (ranges.Any(r => r.Start == i)) output.Append(@"\b ");
            if (ranges.Any(r => r.Start + r.Length == i)) output.Append(@"\b0 ");
            char c = text[i];
            if (c == '\r') continue;
            if (c == '\n') output.Append(@"\par ");
            else if (c is '\\' or '{' or '}') output.Append('\\').Append(c);
            else if (c > 127) output.Append(@"\u").Append((short)c).Append('?');
            else output.Append(c);
        }
        return (text, output.Append(@"\b0 }").ToString());
    }
}
