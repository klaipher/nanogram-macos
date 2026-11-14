import Foundation
import TelegramCore

public extension AppConfiguration {
    func getGeneralValue(_ key: String, orElse defaultValue: Int32) -> Int32 {
        if let value = self.data?[key] as? Double {
            return Int32(value)
        } else {
            return defaultValue
        }
    }
    func getGeneralValue64(_ key: String, orElse defaultValue: Int64) -> Int64 {
        if let value = self.data?[key] as? Double {
            return Int64(value)
        } else {
            return defaultValue
        }
    }
    func getGeneralValueDouble(_ key: String, orElse defaultValue: Double) -> Double {
        if let value = self.data?[key] as? Double {
            return Double(value)
        } else {
            return defaultValue
        }
    }
    func getStringValue(_ key: String, orElse defaultValue: String) -> String {
        if let value = self.data?[key] as? String {
            return value
        } else {
            return defaultValue
        }
    }
    func getBoolValue(_ key: String, orElse defaultValue: Bool) -> Bool {
        if let value = self.data?[key] as? Bool {
            return value
        } else {
            return defaultValue
        }
    }

    /// `rich_message_posting`: 'enabled' | 'premium' | 'disabled'. When 'disabled' the rich text editor UI is
    /// hidden everywhere (attach menu, composer expand button, paste-into-editor).
    var isRichTextEditorEnabled: Bool {
        return getStringValue("rich_message_posting", orElse: "enabled") != "disabled"
    }
}

public enum AppConfigValueParsing {
    public static func int32(_ value: Any?) -> Int32? {
        switch value {
        case let value as Double:
            return value.isFinite && abs(value) < Double(Int32.max) ? Int32(value) : nil
        case let value as Int:
            return Int32(exactly: value)
        case let value as Int32:
            return value
        case let value as String:
            return Int32(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    // Same result as the shared core's StarRefStartParamPrefixes: empty or malformed lists mean "use the default".
    public static func stringList(_ value: Any?) -> [String]? {
        let list: [String]
        switch value {
        case let value as [String]:
            list = value
        case let value as [Any]:
            list = value.compactMap { $0 as? String }
        case let value as String:
            list = [value]
        default:
            return nil
        }
        let nonEmpty = list.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? nil : nonEmpty
    }

    public static let defaultStarRefPrefixes = ["_tgr_"]

    public static func starRefReferrer(startParameter: String, prefixes: [String]?) -> String? {
        for prefix in prefixes ?? defaultStarRefPrefixes where !prefix.isEmpty && startParameter.hasPrefix(prefix) {
            return String(startParameter.dropFirst(prefix.count))
        }
        return nil
    }
}

public extension AppConfiguration {
    func getInt32Value(_ key: String) -> Int32? {
        return AppConfigValueParsing.int32(self.data?[key])
    }

    func getStringListValue(_ key: String) -> [String]? {
        return AppConfigValueParsing.stringList(self.data?[key])
    }

    func starRefReferrer(startParameter: String) -> String? {
        return AppConfigValueParsing.starRefReferrer(startParameter: startParameter, prefixes: getStringListValue("starref_start_param_prefixes"))
    }
}
