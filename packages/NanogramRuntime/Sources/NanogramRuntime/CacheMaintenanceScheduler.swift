import Foundation

public protocol BackgroundActivity: AnyObject {
    var shouldDefer: Bool { get }
    func schedule(_ block: @escaping (@escaping (NSBackgroundActivityScheduler.Result) -> Void) -> Void)
    func invalidate()
}

final class SystemBackgroundActivity: BackgroundActivity {
    private let scheduler: NSBackgroundActivityScheduler

    init(scheduler: NSBackgroundActivityScheduler) {
        self.scheduler = scheduler
    }

    var shouldDefer: Bool {
        return self.scheduler.shouldDefer
    }

    func schedule(_ block: @escaping (@escaping (NSBackgroundActivityScheduler.Result) -> Void) -> Void) {
        self.scheduler.schedule { completion in
            block(completion)
        }
    }

    func invalidate() {
        self.scheduler.invalidate()
    }
}

public final class CacheMaintenanceScheduler {
    public typealias Job = (@escaping () -> Void) -> Void

    public static let interval: TimeInterval = 6 * 60 * 60
    public static let tolerance: TimeInterval = 2 * 60 * 60

    private let activity: BackgroundActivity

    public init(activity: BackgroundActivity, jobs: @escaping (@escaping ([Job]) -> Void) -> Void) {
        self.activity = activity
        activity.schedule { [weak activity] completion in
            jobs { list in
                CacheMaintenanceScheduler.run(list, from: 0, activity: activity, completion: completion)
            }
        }
    }

    public convenience init(bundleIdentifier: String, jobs: @escaping (@escaping ([Job]) -> Void) -> Void) {
        self.init(activity: SystemBackgroundActivity(scheduler: CacheMaintenanceScheduler.makeSystemScheduler(bundleIdentifier: bundleIdentifier)), jobs: jobs)
    }

    deinit {
        self.activity.invalidate()
    }

    static func makeSystemScheduler(bundleIdentifier: String) -> NSBackgroundActivityScheduler {
        let scheduler = NSBackgroundActivityScheduler(identifier: bundleIdentifier + ".cache-eviction")
        scheduler.repeats = true
        scheduler.interval = CacheMaintenanceScheduler.interval
        scheduler.tolerance = CacheMaintenanceScheduler.tolerance
        scheduler.qualityOfService = .background
        return scheduler
    }

    private static func run(_ jobs: [Job], from index: Int, activity: BackgroundActivity?, completion: @escaping (NSBackgroundActivityScheduler.Result) -> Void) {
        guard index < jobs.count else {
            completion(.finished)
            return
        }
        guard let activity, !activity.shouldDefer else {
            completion(.deferred)
            return
        }
        let job = jobs[index]
        job({
            CacheMaintenanceScheduler.run(jobs, from: index + 1, activity: activity, completion: completion)
        })
    }
}
