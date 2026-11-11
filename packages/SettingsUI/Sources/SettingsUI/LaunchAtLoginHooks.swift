import Foundation

public struct LaunchAtLoginHooks {
    public struct State {
        public let isOn: Bool
        public let needsApproval: Bool

        public init(isOn: Bool, needsApproval: Bool) {
            self.isOn = isOn
            self.needsApproval = needsApproval
        }
    }

    public let state: () -> State
    public let setEnabled: (Bool) -> Void

    public init(state: @escaping () -> State, setEnabled: @escaping (Bool) -> Void) {
        self.state = state
        self.setEnabled = setEnabled
    }

    private static var _shared: LaunchAtLoginHooks?

    public static var installed: LaunchAtLoginHooks? {
        return _shared
    }

    public static func install(_ hooks: LaunchAtLoginHooks) {
        assert(Thread.isMainThread, "LaunchAtLoginHooks.install must be called on the main thread")
        _shared = hooks
    }
}
