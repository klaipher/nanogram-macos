import Foundation

public enum SecondTick {
    public static let margin: Double = 0.01

    public static func delayToNextSecond(now: Double) -> Double {
        let fraction = now - now.rounded(.down)
        return 1.0 - fraction + margin
    }
}

public enum AutoNightBoundarySchedule {
    public static let maximumInterval: Double = 3600
    private static let day: Int32 = 86400

    public static func nextCheck(secondsOfDay: Int32, boundaries: [Int32]) -> Double {
        var result = maximumInterval
        for boundary in boundaries {
            var delta = (boundary - secondsOfDay) % day
            if delta < 0 {
                delta += day
            }
            if delta == 0 {
                delta = day
            }
            result = min(result, Double(delta) + 1)
        }
        return result
    }
}
