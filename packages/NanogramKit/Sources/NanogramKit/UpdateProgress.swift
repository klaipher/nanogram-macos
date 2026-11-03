import Foundation

public enum UpdateProgress {
    public static func percentText(current: Int, total: Int) -> String {
        guard total > 0 else {
            return ""
        }
        let fraction = min(max(Double(current) / Double(total), 0), 1)
        return "\(Int(fraction * 100))%"
    }
}
