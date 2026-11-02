import Synchronization

// Entry point for Nanogram's own code. main.swift calls installHooks() once at launch;
// later features register their hooks here.
public enum Nanogram {
    private static let installs = Mutex(0)

    public static var installedHookCount: Int {
        installs.withLock { $0 }
    }

    public static func installHooks() {
        let first = installs.withLock { count -> Bool in
            guard count == 0 else { return false }
            count += 1
            return true
        }
        guard first else { return }
        Branding.installMenuHook()
    }
}
