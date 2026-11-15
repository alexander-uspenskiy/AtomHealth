import Foundation

/// The bot writes the Telegram HTML subset (`<b> <i> <code> <pre>` plus `&lt; &gt; &amp;` entities). This turns it into
/// plain or styled text without a web view.
public enum TelegramHTML {
    struct Run { var text: String; var bold = false, italic = false, code = false }

    static func runs(_ html: String) -> [Run] {
        var out: [Run] = [], buf = ""
        var bold = 0, italic = 0, code = 0
        func flush() {
            if !buf.isEmpty { out.append(Run(text: buf, bold: bold > 0, italic: italic > 0, code: code > 0)); buf = "" }
        }
        var i = html.startIndex
        while i < html.endIndex {
            let ch = html[i]
            if ch == "<", let close = html[i...].firstIndex(of: ">"),
               !html[html.index(after: i)..<close].contains("<"),                       // a lone "<" is just text
               let first = html[html.index(after: i)..<close].drop(while: { $0 == "/" }).first, first.isLetter {
                let raw = html[html.index(after: i)..<close].trimmingCharacters(in: .whitespaces).lowercased()
                let closing = raw.hasPrefix("/")
                let name = String(raw.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }))
                let known = ["b", "strong", "i", "em", "code", "pre"]
                if known.contains(name) {
                    flush()
                    let d = closing ? -1 : 1
                    switch name {
                    case "b", "strong": bold = max(0, bold + d)
                    case "i", "em": italic = max(0, italic + d)
                    default: code = max(0, code + d)
                    }
                    i = html.index(after: close); continue
                }
                if !name.isEmpty || raw == "br" { i = html.index(after: close); if name == "br" { buf.append("\n") }; continue }
            }
            if ch == "&", let semi = html[i...].prefix(10).firstIndex(of: ";") {
                let ent = String(html[html.index(after: i)..<semi])
                let map = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " "]
                if let r = map[ent] { buf.append(r); i = html.index(after: semi); continue }
            }
            buf.append(ch); i = html.index(after: i)
        }
        flush()
        return out
    }

    public static func plain(_ html: String) -> String { runs(html).map(\.text).joined() }

    public static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        for r in runs(html) {
            var a = AttributedString(r.text)
            var intent: InlinePresentationIntent = []
            if r.bold { intent.insert(.stronglyEmphasized) }
            if r.italic { intent.insert(.emphasized) }
            if r.code { intent.insert(.code) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            result.append(a)
        }
        return result
    }
}
