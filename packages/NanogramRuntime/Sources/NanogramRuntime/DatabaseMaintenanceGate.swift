import Foundation

public enum DatabaseMaintenanceGate {
    public static let minimumUserIdle: Double = 10 * 60
    public static let maximumLiveBytes: Int64 = 1024 * 1024 * 1024

    public static func allowsVacuum(userIdle: Double) -> Bool {
        return userIdle >= self.minimumUserIdle
    }
}
