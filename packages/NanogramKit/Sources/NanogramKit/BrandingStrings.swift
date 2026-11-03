import Foundation

public enum BrandingStrings {
    static let pluralSuffixes = ["", "_zero", "_one", "_two", "_few", "_many", "_other"]
    static let networkNames = ["Premium", "Stars", "Passport", "Desktop", "Web", "Business", "Gateway", "account", "cloud", "server", "servers", "Support", "FAQ"]
    static let otherScriptNames = ["تيليجرام", "تليجرام", "تلگرام", "텔레그램", "טלגרם"]

    static let upstreamName: NSRegularExpression = {
        let network = networkNames.joined(separator: "|")
        let latin = "(?<![\\p{L}\\p{N}_./@])Telegram(?![\\p{L}\\p{N}_]|\\.(?:org|me)\\b|[ \\u00A0](?:\(network))\\b)"
        let pattern = ([latin] + otherScriptNames).joined(separator: "|")
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("invalid branding pattern: \(error)")
        }
    }()

    static func replacement(for key: String, languageCode: String) -> String {
        guard eitherAppKeys.contains(key) else {
            return Branding.appName
        }
        return languageCode == "en" ? "\(Branding.appName) or \(Branding.upstreamName)" : "\(Branding.appName) / \(Branding.upstreamName)"
    }

    static func rebranded(_ value: String, key: String, languageCode: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        let template = NSRegularExpression.escapedTemplate(for: replacement(for: key, languageCode: languageCode))
        return upstreamName.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    public static func brand(_ strings: [String: String], languageCode: String) -> [String: String] {
        var result = strings
        for key in identityKeys {
            for suffix in pluralSuffixes {
                if let value = strings[key + suffix] {
                    result[key + suffix] = rebranded(value, key: key, languageCode: languageCode)
                }
            }
        }
        if languageCode == "en" {
            for (key, text) in englishTexts where strings[key] != nil {
                result[key] = text
            }
        }
        return result
    }
}
