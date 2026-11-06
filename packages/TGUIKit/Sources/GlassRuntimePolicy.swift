import Foundation

public enum GlassGroup: String, CaseIterable {
    case chatHeader
    case inputRow
    case tabBar
    case toasts
}

public enum GlassDebug {
    public static func parse(_ value: String?) -> Set<GlassGroup> {
        guard let value else {
            return []
        }
        var result = Set<GlassGroup>()
        for part in value.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name == "all" {
                return Set(GlassGroup.allCases)
            }
            if let group = GlassGroup(rawValue: name) {
                result.insert(group)
            }
        }
        return result
    }

#if DEBUG
    public static let disabledGroups: Set<GlassGroup> = parse(UserDefaults.standard.string(forKey: "GlassDisable"))
#else
    public static let disabledGroups: Set<GlassGroup> = []
#endif

    public static func isDisabled(_ group: GlassGroup?) -> Bool {
        guard let group else {
            return false
        }
        return disabledGroups.contains(group)
    }
}
