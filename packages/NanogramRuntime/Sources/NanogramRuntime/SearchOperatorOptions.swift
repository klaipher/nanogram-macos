import Foundation
import NanogramDebug
@_exported import NanogramFeatures

// The grammar and the parser are the iOS core's NanogramFeatures module (docs/specs/search-operators.md there), compiled
// through packages/NanogramFeatures. Only the Mac's switch and its choice of operator types live here.
extension SearchOperators {
    public static let optionId = "search.operators"

    public static let debugOption = NanogramDebugOption.toggle(id: optionId, section: "Search", title: "Search operators", detail: "Operators: from:, before:, after:, date:, type: (photo, video, file, link, voice, music, gif, round, poll, pinned). Dates are YYYY-MM-DD, YYYY-MM, YYYY, today or yesterday. Anything else stays part of the search. Secret chats search without operators.", defaultValue: true).userFacing("Narrow a search inside a chat: from:name, before:, after:, date:, type: (photo, video, file, link, voice, music, gif, round, poll, pinned). Dates look like 2026-11-14, 2026-11 or 2026. Not used in secret chats.")

    // `contact`, `geo` and `mention` have no tag mapping on the Mac; they stay plain search text.
    public static let macSupportedTypes: Set<SearchOperatorType> = [.photo, .video, .file, .link, .voice, .music, .gif, .round, .poll, .pinned]

    public static func isEnabled(in settings: NanogramDebugSettings) -> Bool {
        return settings.bool(optionId)
    }

    public static var isEnabled: Bool {
        return SearchOperators.isEnabled(in: NanogramDebugSettings.shared)
    }
}
