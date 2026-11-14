import Foundation

// File contents for developers reading the archive: English only, not shown in the app.
extension NanogramReport {
    static func settingsFileText(_ lines: [String]) -> String {
        return lines.isEmpty ? "No diagnostic settings are registered in this build.\n" : lines.joined(separator: "\n") + "\n"
    }

    public static func readme(device: NanogramReportDevice, sections: [(title: String, files: [(path: String, size: Int)])], date: Date) -> String {
        var lines = [
            "Nanogram diagnostic report",
            "",
            "Created: \(timestamp(date))",
            "App: Nanogram macOS \(device.appVersion) (\(device.buildNumber))",
            "Mac model: \(device.model)",
            "Chip: \(device.chip)",
            "macOS: \(device.systemVersion)",
            "",
            "Contents",
        ]
        for section in sections {
            if section.files.isEmpty {
                lines.append("- \(section.title): none")
            } else {
                let total = section.files.reduce(0) { $0 + $1.size }
                lines.append("- \(section.title): \(section.files.count) file(s), \(total) bytes")
                for file in section.files {
                    lines.append("    \(file.path) (\(file.size) bytes)")
                }
            }
        }
        lines.append("- Diagnostic settings: \(settingsFileName)")
        lines.append("")
        lines.append("Not included: message text, contact lists, phone numbers beyond what the logs already redact.")
        return lines.joined(separator: "\n") + "\n"
    }
}
