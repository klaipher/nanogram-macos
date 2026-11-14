import Foundation
import NanogramDebug

// Grammar: docs/specs/search-operators.md (shared with the iOS and Android apps; the iOS repo owns the spec).
public enum SearchOperatorType: String, CaseIterable, Sendable {
    case photo
    case video
    case file
    case link
    case voice
    case music
    case gif
    case round
    case poll
    case pinned
}

public struct SearchOperatorQuery: Equatable, Sendable {
    public var text: String
    // The `from:` value as typed. It stays here until the caller resolves it to a peer.
    public var fromName: String?
    public var fromRawToken: String?
    public var minDate: Int32?
    public var maxDate: Int32?
    public var type: SearchOperatorType?

    public init(text: String, fromName: String? = nil, fromRawToken: String? = nil, minDate: Int32? = nil, maxDate: Int32? = nil, type: SearchOperatorType? = nil) {
        self.text = text
        self.fromName = fromName
        self.fromRawToken = fromRawToken
        self.minDate = minDate
        self.maxDate = maxDate
        self.type = type
    }

    public var hasOperators: Bool {
        return self.fromName != nil || self.minDate != nil || self.maxDate != nil || self.type != nil
    }

    public var isMe: Bool {
        return self.fromName?.lowercased() == "me"
    }

    // A name the server can resolve as a public username. Anything else (a quoted display name) stays plain text on the Mac.
    public var resolvableUsername: String? {
        guard let name = self.fromName, !self.isMe else {
            return nil
        }
        let bytes = Array(name.utf8)
        guard bytes.count >= 5, bytes.count <= 32 else {
            return nil
        }
        let isLetter: (UInt8) -> Bool = { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
        guard isLetter(bytes[0]) else {
            return nil
        }
        for byte in bytes where !(isLetter(byte) || (byte >= 48 && byte <= 57) || byte == 95) {
            return nil
        }
        return name
    }

    public var isEmptyRange: Bool {
        if let minDate = self.minDate, let maxDate = self.maxDate {
            return minDate >= maxDate
        }
        return false
    }

    // The text with the `from:` token put back, for a name that did not resolve.
    public func textRestoringFrom() -> String {
        guard let raw = self.fromRawToken else {
            return self.text
        }
        return self.text.isEmpty ? raw : self.text + " " + raw
    }
}

public enum SearchOperators {
    public static let optionId = "search.operators"

    public static let debugOption = NanogramDebugOption.toggle(id: optionId, section: "Search", title: "Search operators", detail: "Operators: from:, before:, after:, date:, type: (photo, video, file, link, voice, music, gif, round, poll, pinned). Dates are YYYY-MM-DD, YYYY-MM, YYYY, today or yesterday. Anything else stays part of the search. Secret chats search without operators.", defaultValue: true).userFacing("Narrow a search inside a chat: from:name, before:, after:, date:, type: (photo, video, file, link, voice, music, gif, round, poll, pinned). Dates look like 2026-11-14, 2026-11 or 2026. Not used in secret chats.")

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(optionId)
    }

    public static var isEnabled: Bool {
        return SearchOperators.isEnabled(in: NanogramDebugSettings.shared)
    }

    public static func parse(_ query: String, now: Date = Date(), calendar: Calendar = Calendar.current) -> SearchOperatorQuery {
        var plain: [String] = []
        var fromName: String?
        var fromRaw: String?
        var beforeMax: Int32?
        var afterMin: Int32?
        var dateOnly: (Int32, Int32)?
        var type: SearchOperatorType?

        for token in tokenize(query) {
            guard let colon = token.firstIndex(of: ":") else {
                plain.append(token)
                continue
            }
            let name = token[token.startIndex ..< colon].lowercased()
            var value = String(token[token.index(after: colon)...])
            if value.hasPrefix("\"") {
                if value.count >= 2 && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                } else {
                    plain.append(token)
                    continue
                }
            }
            if value.isEmpty {
                plain.append(token)
                continue
            }
            switch name {
            case "from":
                var handle = value
                if handle.hasPrefix("@") {
                    handle.removeFirst()
                }
                if handle.isEmpty {
                    plain.append(token)
                } else {
                    fromName = handle
                    fromRaw = token
                }
            case "before", "after", "date":
                guard let range = dateRange(value, now: now, calendar: calendar) else {
                    plain.append(token)
                    continue
                }
                switch name {
                case "before":
                    beforeMax = range.0
                case "after":
                    afterMin = range.1
                default:
                    dateOnly = range
                }
            case "type":
                if let parsed = SearchOperatorType.named(value.lowercased()) {
                    type = parsed
                } else {
                    plain.append(token)
                }
            default:
                plain.append(token)
            }
        }

        var minDate = afterMin
        var maxDate = beforeMax
        if let dateOnly {
            minDate = max(minDate ?? dateOnly.0, dateOnly.0)
            maxDate = min(maxDate ?? dateOnly.1, dateOnly.1)
        }
        let result = SearchOperatorQuery(text: plain.joined(separator: " "), fromName: fromName, fromRawToken: fromRaw, minDate: minDate, maxDate: maxDate, type: type)
        return result.hasOperators ? result : SearchOperatorQuery(text: query)
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for character in query {
            if character == "\"" {
                // A quote opens only right after "name:", so a quote inside plain words stays as typed.
                if !inQuote && current.hasSuffix(":") {
                    inQuote = true
                } else if inQuote {
                    inQuote = false
                }
                current.append(character)
            } else if character.isWhitespace && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            if inQuote, let space = current.firstIndex(where: { $0.isWhitespace }) {
                // Unclosed quote: the first word is the token, the rest are ordinary words.
                tokens.append(String(current[current.startIndex ..< space]))
                tokens.append(contentsOf: current[space...].split(whereSeparator: { $0.isWhitespace }).map(String.init))
            } else {
                tokens.append(current)
            }
        }
        return tokens
    }

    // Start of the range and its end (exclusive), as Unix seconds.
    static func dateRange(_ value: String, now: Date, calendar: Calendar) -> (Int32, Int32)? {
        let lower = value.lowercased()
        let start: Date
        let end: Date
        if lower == "today" || lower == "yesterday" {
            let today = calendar.startOfDay(for: now)
            guard let day = lower == "today" ? today : calendar.date(byAdding: .day, value: -1, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            start = day
            end = next
        } else {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1 ... 3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
                return nil
            }
            guard parts[0].count == 4, let year = Int(parts[0]), (1970 ... 2100).contains(year) else {
                return nil
            }
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            var unit: Calendar.Component = .year
            if parts.count >= 2 {
                guard parts[1].count == 2, let month = Int(parts[1]), (1 ... 12).contains(month) else {
                    return nil
                }
                components.month = month
                unit = .month
            }
            if parts.count == 3 {
                guard parts[2].count == 2, let day = Int(parts[2]), (1 ... 31).contains(day) else {
                    return nil
                }
                components.day = day
                unit = .day
            }
            guard let first = calendar.date(from: components) else {
                return nil
            }
            let check = calendar.dateComponents([.year, .month, .day], from: first)
            guard check.year == components.year, check.month == components.month, check.day == components.day,
                  let next = calendar.date(byAdding: unit, value: 1, to: first) else {
                return nil
            }
            start = first
            end = next
        }
        guard let startSeconds = Int32(exactly: Int64(start.timeIntervalSince1970)),
              let endSeconds = Int32(exactly: Int64(end.timeIntervalSince1970)) else {
            return nil
        }
        return (startSeconds, endSeconds)
    }
}

extension SearchOperatorType {
    static func named(_ value: String) -> SearchOperatorType? {
        return SearchOperatorType(rawValue: value)
    }
}
