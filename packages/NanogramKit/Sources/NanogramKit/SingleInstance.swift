import AppKit

// Both editions share one bundle ID and one app group, so only one Nanogram process may run at a time:
// a later launch activates the instance already running and quits before touching the shared data.
public enum SingleInstance {
    struct Instance: Equatable, Sendable {
        let pid: pid_t
        let launchDate: Date?
    }

    // The oldest launch wins; a tie goes to the lower pid, so two simultaneous launches never both quit.
    static func instanceToActivate(current: Instance, others: [Instance]) -> Instance? {
        func precedes(_ lhs: Instance, _ rhs: Instance) -> Bool {
            let left = lhs.launchDate ?? .distantFuture
            let right = rhs.launchDate ?? .distantFuture
            return left != right ? left < right : lhs.pid < rhs.pid
        }
        guard let oldest = others.filter({ $0.pid != current.pid }).min(by: precedes), precedes(oldest, current) else {
            return nil
        }
        return oldest
    }

    // Returns false after activating an older running instance; the caller then exits.
    public static func ensure(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let bundleIdentifier else {
            return true
        }
        let current = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let me = Instance(pid: current.processIdentifier, launchDate: current.launchDate)
        let others = running.map { Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let winner = instanceToActivate(current: me, others: others),
              let app = running.first(where: { $0.processIdentifier == winner.pid }) else {
            return true
        }
        MainActor.assumeIsolated {
            activate(app)
        }
        return false
    }

    // Activation is cooperative since macOS 14: a process may only hand activation to another app.
    // Checking in with the window server (we are about to quit, so creating NSApp here is harmless)
    // lets the launch the user just made yield its activation to the running instance.
    @MainActor
    private static func activate(_ app: NSRunningApplication) {
        let application = NSApplication.shared
        application.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
    }
}
