import Foundation

public enum UpdateNotes {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]
    private static let lineEndingTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "ul", "ol"]
    private static let droppedContentTags: Set<String> = ["script", "style"]

    public static func plainText(from markup: String?) -> String {
        guard let markup = markup, !markup.isEmpty else {
            return ""
        }
        var text = decodeEntities(strippingTags(markup))
        while let range = text.range(of: "   ") {
            text.replaceSubrange(range, with: "  ")
        }
        text = text.replacingOccurrences(of: "•", with: "\n•")
        text = text.replacingOccurrences(of: "\t", with: "  ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingTags(_ markup: String) -> String {
        var output = ""
        var index = markup.startIndex
        while index < markup.endIndex {
            let character = markup[index]
            guard character == "<" else {
                output.append(character)
                index = markup.index(after: index)
                continue
            }
            guard let close = markup[index...].firstIndex(of: ">") else {
                break
            }
            let body = markup[markup.index(after: index)..<close]
            let isClosing = body.hasPrefix("/")
            let name = body.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            index = markup.index(after: close)
            if !isClosing && droppedContentTags.contains(name) {
                let closing = "</" + name
                if let end = markup.range(of: closing, options: .caseInsensitive, range: index..<markup.endIndex),
                   let endClose = markup[end.upperBound...].firstIndex(of: ">") {
                    index = markup.index(after: endClose)
                } else {
                    index = markup.endIndex
                }
            } else if name == "br" || (isClosing && lineEndingTags.contains(name)) {
                output.append("\n")
            } else if name == "li" && !isClosing {
                output.append("• ")
            }
        }
        return output
    }

    private static func decodeEntities(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
               let decoded = decodeEntity(String(text[text.index(after: index)..<semicolon])) {
                output.append(decoded)
                index = text.index(after: semicolon)
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }

    private static func decodeEntity(_ name: String) -> String? {
        if let named = namedEntities[name] {
            return named
        }
        guard name.hasPrefix("#") else {
            return nil
        }
        let digits = name.dropFirst()
        let parsed: Int?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            parsed = Int(digits.dropFirst(), radix: 16)
        } else {
            parsed = Int(digits, radix: 10)
        }
        guard let value = parsed.flatMap({ UInt32(exactly: $0) }), let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return String(Character(scalar))
    }
}
