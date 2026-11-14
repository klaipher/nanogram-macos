import Foundation
import NanogramDebug

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

    static let trackingPrefixes: [String] = ["utm_", "pk_", "mtm_", "hsa_"]

    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "gbraid", "wbraid", "dclid", "gad_source", "gad_campaignid",
        "msclkid", "yclid", "twclid", "ttclid", "li_fat_id", "epik", "rdt_cid",
        "igshid", "igsh", "mc_eid", "mc_cid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "vero_id", "vero_conv", "oly_enc_id", "oly_anon_id", "rb_clickid", "s_cid", "wickedid",
        "_openstat", "ref_src", "ref_url", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        "ml_subscriber", "ml_subscriber_hash", "irclickid", "cjevent"
    ]

    static let hostSpecificParameters: [(hosts: [String], names: Set<String>)] = [
        (["youtube.com", "youtu.be", "music.youtube.com", "spotify.com", "spotify.link", "open.spotify.com"], ["si", "feature", "pp"]),
        (["twitter.com", "x.com", "mobile.twitter.com"], ["s", "t"]),
        (["instagram.com", "threads.net", "threads.com"], ["igshid", "igsh", "xmt", "slof"]),
        (["facebook.com", "m.facebook.com", "fb.com"], ["mibextid", "rdid", "share_url", "sfnsn"]),
        (["tiktok.com", "vm.tiktok.com"], ["is_from_webapp", "sender_device", "sender_web_id", "web_id", "_r", "_t", "share_app_id", "share_link_id", "share_item_id", "source", "u_code", "tt_from", "enter_from", "social_sharing"]),
        (["amazon.com", "amazon.de", "amazon.co.uk", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca", "amazon.co.jp", "amzn.to"], ["tag", "linkcode", "linkid", "ascsubtag", "ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_p", "pf_rd_r"]),
        (["linkedin.com"], ["trk", "trackingid", "refid", "lipi", "midtoken", "midsig", "trkemail", "eid", "otptoken"]),
        (["reddit.com", "redd.it"], ["share_id", "ref", "ref_source"]),
        (["medium.com"], ["source", "sk"]),
    ]

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

    public static func strippingTracking(_ link: String) -> String {
        guard let schemeEnd = link.range(of: "://") else {
            return link
        }
        let scheme = link[link.startIndex ..< schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else {
            return link
        }
        guard let host = hostOf(link), !telegramHosts.contains(host) else {
            return link
        }
        guard let questionMark = link.firstIndex(of: "?") else {
            return link
        }
        let fragmentStart = link.firstIndex(of: "#")
        if let fragmentStart = fragmentStart, fragmentStart < questionMark {
            return link
        }
        let queryEnd = fragmentStart ?? link.endIndex
        let query = link[link.index(after: questionMark) ..< queryEnd]
        let specific = hostSpecificParameters.filter { entry in
            entry.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        }
        var kept: [Substring] = []
        var removed = false
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let rawName = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map { String($0) } ?? ""
            let name = (rawName.removingPercentEncoding ?? rawName).lowercased()
            if isTracking(name, hostSpecific: specific) {
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

    private static func isTracking(_ name: String, hostSpecific: [(hosts: [String], names: Set<String>)]) -> Bool {
        if name.isEmpty {
            return false
        }
        if trackingParameters.contains(name) {
            return true
        }
        for prefix in trackingPrefixes where name.hasPrefix(prefix) {
            return true
        }
        for entry in hostSpecific where entry.names.contains(name) {
            return true
        }
        return false
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
