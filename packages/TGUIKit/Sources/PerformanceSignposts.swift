import Cocoa
import SwiftSignalKit

/// The signposts of both apps live in the shared core (`NanogramSignposts`, `UserSignpost`, `PerformanceSignpostName`
/// in SwiftSignalKit), so iOS and macOS emit identical names with the same API. See docs/profiling.md, "Signposts".
public typealias PerformanceSignposts = NanogramSignposts

public extension NanogramSignposts.OneShot {
    func endAfterNextCommit() {
        DispatchQueue.main.async {
            CATransaction.setCompletionBlock {
                self.end()
            }
        }
    }
}

public enum LaunchUsableSignpost {
    private static let current = Atomic<NanogramSignposts.OneShot?>(value: nil)

    public static func begin() {
        current.swap(NanogramSignposts.OneShot(PerformanceSignpostName.launchToChatListUsable))?.end()
    }

    public static func endAfterNextCommit() {
        current.swap(nil)?.endAfterNextCommit()
    }
}
