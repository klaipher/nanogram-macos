import Foundation
import NanogramDebug

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

    static func named(_ value: String) -> SearchOperatorType? {
        switch value {
        case "photo", "photos", "image", "images":
            return .photo
        case "video", "videos":
            return .video
        case "file", "files", "doc", "document", "documents":
            return .file
        case "link", "links", "url", "urls":
            return .link
        case "voice", "voicemessage":
            return .voice
        case "music", "audio":
            return .music
        case "gif", "gifs":
            return .gif
        case "round", "roundvideo", "circle":
            return .round
        case "poll", "polls":
            return .poll
        case "pinned":
            return .pinned
        default:
            return nil
        }
    }
}

public enum SearchOperatorSender: Equatable, Sendable {
    case username(String)
    case userId(Int64)
}

public struct SearchOperatorQuery: Equatable, Sendable {
    public var text: String
    public var sender: SearchOperatorSender?
    public var minDate: Int32?
    public var maxDate: Int32?
    public var type: SearchOperatorType?
    public var hasOperators: Bool

    public init(text: String, sender: SearchOperatorSender? = nil, minDate: Int32? = nil, maxDate: Int32? = nil, type: SearchOperatorType? = nil, hasOperators: Bool = false) {
        self.text = text
        self.sender = sender
        self.minDate = minDate
        self.maxDate = maxDate
        self.type = type
        self.hasOperators = hasOperators
    }

    public var isEmptyRange: Bool {
        if let minDate = self.minDate, let maxDate = self.maxDate {
            return minDate > maxDate
        }
        return false
    }
}

public enum SearchOperators {
    public static let optionId = "search.operators"

    public static let debugOption = NanogramDebugOption.toggle(id: optionId, section: "Search", title: "Search operators", detail: "In a chat search, from:name, before:, after: and date: (YYYY-MM-DD, today or yesterday) and type: (photo, video, file, link, voice, music, gif, round, poll, pinned) narrow the results. Anything else stays part of the search.", defaultValue: true).userFacing()

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(optionId)
    }

    public static var isEnabled: Bool {
        return SearchOperators.isEnabled(in: NanogramDebugSettings.shared)
    }

    public static func parse(_ query: String, now: Date = Date(), calendar: Calendar = Calendar.current) -> SearchOperatorQuery {
        var plain: [Substring] = []
        var sender: SearchOperatorSender?
        var type: SearchOperatorType?
        var after: Int32?
        var before: Int32?
        var onDate: (start: Int32, end: Int32)?
        var consumed = false

        for token in query.split(whereSeparator: { $0.isWhitespace }) {
            guard let separator = token.firstIndex(of: ":") else {
                plain.append(token)
                continue
            }
            let key = token[token.startIndex ..< separator].lowercased()
            let value = String(token[token.index(after: separator)...])
            switch key {
            case "from":
                if let parsed = parseSender(value) {
                    sender = parsed
                    consumed = true
                    continue
                }
            case "type":
                if let parsed = SearchOperatorType.named(value.lowercased()) {
                    type = parsed
                    consumed = true
                    continue
                }
            case "after":
                if let day = parseDay(value, now: now, calendar: calendar) {
                    after = day.start
                    consumed = true
                    continue
                }
            case "before":
                if let day = parseDay(value, now: now, calendar: calendar) {
                    before = day.start - 1
                    consumed = true
                    continue
                }
            case "date":
                if let day = parseDay(value, now: now, calendar: calendar) {
                    onDate = (day.start, day.end)
                    consumed = true
                    continue
                }
            default:
                break
            }
            plain.append(token)
        }

        guard consumed else {
            return SearchOperatorQuery(text: query)
        }

        var minDate: Int32?
        var maxDate: Int32?
        for value in [after, onDate?.start].compactMap({ $0 }) {
            minDate = max(minDate ?? value, value)
        }
        for value in [before, onDate?.end].compactMap({ $0 }) {
            maxDate = min(maxDate ?? value, value)
        }
        return SearchOperatorQuery(text: plain.joined(separator: " "), sender: sender, minDate: minDate, maxDate: maxDate, type: type, hasOperators: true)
    }

    static func parseSender(_ value: String) -> SearchOperatorSender? {
        var name = Substring(value)
        if name.hasPrefix("@") {
            name = name.dropFirst()
        }
        guard !name.isEmpty else {
            return nil
        }
        if name.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            if let id = Int64(name), id > 0 {
                return .userId(id)
            }
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
        return .username(String(name))
    }

    static func parseDay(_ value: String, now: Date, calendar: Calendar) -> (start: Int32, end: Int32)? {
        let day: Date
        switch value.lowercased() {
        case "today":
            day = calendar.startOfDay(for: now)
        case "yesterday":
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            day = yesterday
        default:
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2, let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else {
                return nil
            }
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = dayOfMonth
            guard let date = calendar.date(from: components) else {
                return nil
            }
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            guard check.year == year, check.month == month, check.day == dayOfMonth else {
                return nil
            }
            day = calendar.startOfDay(for: date)
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
            return nil
        }
        let start = day.timeIntervalSince1970
        let end = next.timeIntervalSince1970 - 1
        guard start >= 0, end <= Double(Int32.max) else {
            return nil
        }
        return (Int32(start), Int32(end))
    }
}
