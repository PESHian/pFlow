import AppKit

enum TemplateTextStyle {
    static let heading = NSAttributedString.Key("com.pesh.template.boldHeading")

    /// Supply the same words in rich and plain forms. The receiving app chooses
    /// what it supports; plain text never contains artificial bold markers.
    static func representations(for source: NSAttributedString) -> [NSPasteboard.PasteboardType: Data] {
        let whole = NSRange(location: 0, length: source.length)
        var headings: [NSRange] = []
        source.enumerateAttribute(heading, in: whole) { value, range, _ in
            if value as? Bool == true { headings.append(range) }
        }
        guard !headings.isEmpty else { return [:] }
        let rich = NSMutableAttributedString(string: source.string,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        for range in headings {
            rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: range)
        }
        var data: [NSPasteboard.PasteboardType: Data] = [:]
        data[.rtf] = try? rich.data(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        let ns = source.string as NSString
        var html = "<html><body><!--StartFragment--><span style=\"white-space:pre-wrap\">"
        var cursor = 0
        for range in headings {
            html += escape(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            html += "<b>" + escape(ns.substring(with: range)) + "</b>"
            cursor = NSMaxRange(range)
        }
        html += escape(ns.substring(from: cursor)) + "</span><!--EndFragment--></body></html>"
        data[.html] = Data(html.utf8)
        return data
    }
}
