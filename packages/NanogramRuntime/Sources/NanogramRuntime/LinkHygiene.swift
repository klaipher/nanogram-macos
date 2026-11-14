import Foundation
import NanogramDebug

public struct TrackingParameterList: Sendable {
    private struct Rule: Sendable {
        let name: String
        let isPrefix: Bool
        let host: String?
    }

    private let rules: [Rule]

    public init(fileContents: String) {
        var rules: [Rule] = []
        for rawLine in fileContents.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            var namePart = line
            var host: String?
            if let bar = line.firstIndex(of: "|") {
                namePart = String(line[line.startIndex ..< bar])
                host = String(line[line.index(after: bar)...]).lowercased()
            }
            let isPrefix = namePart.hasSuffix("*")
            if isPrefix {
                namePart.removeLast()
            }
            if namePart.isEmpty {
                continue
            }
            rules.append(Rule(name: namePart.lowercased(), isPrefix: isPrefix, host: host))
        }
        self.rules = rules
    }

    public var ruleCount: Int {
        return self.rules.count
    }

    public func isTracking(name: String, host: String) -> Bool {
        let name = name.lowercased()
        let host = host.lowercased()
        for rule in self.rules {
            if let ruleHost = rule.host, host != ruleHost && !host.hasSuffix("." + ruleHost) {
                continue
            }
            if rule.isPrefix ? name.hasPrefix(rule.name) : name == rule.name {
                return true
            }
        }
        return false
    }
}

public enum LinkHygiene {
    public static let stripOptionId = "links.stripTracking"
    public static let confirmOptionId = "links.confirmTelegramLinks"

    public static let stripOption = NanogramDebugOption.toggle(id: stripOptionId, section: "Links", title: "Remove tracking from links", detail: "Opening or copying a link drops tracking parameters such as utm_source, fbclid and gclid. Your messages are never changed.", defaultValue: false).userFacing()

    public static let confirmOption = NanogramDebugOption.toggle(id: confirmOptionId, section: "Links", title: "Ask before opening Telegram links", detail: "Links to t.me and tg:// ask for confirmation first, since they can join a channel or open a bot.", defaultValue: false).userFacing()

    public static func stripsTracking(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(stripOptionId)
    }

    public static func confirmsTelegramLinks(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(confirmOptionId)
    }

    public static var stripsTracking: Bool {
        return LinkHygiene.stripsTracking(in: NanogramDebugSettings.shared)
    }

    public static var confirmsTelegramLinks: Bool {
        return LinkHygiene.confirmsTelegramLinks(in: NanogramDebugSettings.shared)
    }

    public static func cleanedIfEnabled(_ link: String) -> String {
        return LinkHygiene.stripsTracking ? LinkHygiene.strippingTracking(link) : link
    }

    // Mirrors docs/specs/link-tracking-params.txt, which the iOS repo owns; a test compares the two.
    static let standardList = TrackingParameterList(fileContents: """
    utm_*
    fbclid
    gclid
    gclsrc
    dclid
    gbraid
    wbraid
    msclkid
    twclid
    ttclid
    li_fat_id
    igshid
    igsh
    mc_eid
    mc_cid
    _hsenc
    _hsmi
    __hssc
    __hstc
    __hsfp
    hsctatracking
    mkt_tok
    oly_anon_id
    oly_enc_id
    vero_id
    vero_conv
    yclid
    ysclid
    _openstat
    ref_src
    ref_url
    s_cid
    spm
    scm
    si|youtube.com
    si|youtu.be
    si|open.spotify.com
    si|music.youtube.com
    feature|youtube.com
    pp|youtube.com
    ref|amazon.com
    tag|amazon.com
    pd_rd_*|amazon.com
    pf_rd_*|amazon.com
    share_id|tiktok.com
    is_copy_url|tiktok.com
    is_from_webapp|tiktok.com
    sender_device|tiktok.com
    refsrc|facebook.com
    __tn__|facebook.com
    __cft__*|facebook.com
    """)

    static let telegramHosts: Set<String> = ["t.me", "telegram.me", "telegram.dog", "telesco.pe"]

    public static func isTelegramLink(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tg://") || trimmed.hasPrefix("tg:") {
            return true
        }
        guard let host = hostOf(trimmed) else {
            return false
        }
        return telegramHosts.contains(host)
    }

    public static func strippingTracking(_ link: String, list: TrackingParameterList = LinkHygiene.standardList) -> String {
        guard let schemeEnd = link.range(of: "://") else {
            return link
        }
        let scheme = link[link.startIndex ..< schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else {
            return link
        }
        guard let host = hostOf(link), let questionMark = link.firstIndex(of: "?") else {
            return link
        }
        let fragmentStart = link.firstIndex(of: "#")
        if let fragmentStart = fragmentStart, fragmentStart < questionMark {
            return link
        }
        let queryEnd = fragmentStart ?? link.endIndex
        let query = link[link.index(after: questionMark) ..< queryEnd]
        var kept: [Substring] = []
        var removed = false
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let rawName = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map { String($0) } ?? ""
            let name = rawName.removingPercentEncoding ?? rawName
            if !name.isEmpty && list.isTracking(name: name, host: host) {
                removed = true
            } else {
                kept.append(item)
            }
        }
        guard removed else {
            return link
        }
        var result = String(link[link.startIndex ..< questionMark])
        let remainder = kept.filter { !$0.isEmpty }
        if !remainder.isEmpty {
            result += "?" + remainder.joined(separator: "&")
        }
        if let fragmentStart = fragmentStart {
            result += String(link[fragmentStart...])
        }
        return result
    }

    private static func hostOf(_ link: String) -> String? {
        guard let schemeEnd = link.range(of: "://") else {
            return nil
        }
        var rest = link[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[rest.startIndex ..< end]
        }
        if let at = rest.lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        if let colon = rest.lastIndex(of: ":"), !rest.contains("]") {
            rest = rest[rest.startIndex ..< colon]
        }
        let host = rest.lowercased()
        return host.isEmpty ? nil : host
    }
}
