import Foundation

public enum UpdateCheckSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isBackgroundCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else {
            return true
        }
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= interval
    }
}
