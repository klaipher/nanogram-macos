import Cocoa

public struct DeveloperLogExport {
    public let id: String
    public let title: String
    public let send: (NSWindow?) -> Void

    public init(id: String, title: String, send: @escaping (NSWindow?) -> Void) {
        self.id = id
        self.title = title
        self.send = send
    }
}

public struct DeveloperHooks {
    public let openNanogramSwitches: (() -> Void)?
    public let logExports: [DeveloperLogExport]
    public let sendLogs: ((NSWindow?) -> Void)?

    public init(openNanogramSwitches: (() -> Void)? = nil, logExports: [DeveloperLogExport] = [], sendLogs: ((NSWindow?) -> Void)? = nil) {
        self.openNanogramSwitches = openNanogramSwitches
        self.logExports = logExports
        self.sendLogs = sendLogs
    }

    private static var _shared: DeveloperHooks?

    public static var isInstalled: Bool {
        return _shared != nil
    }

    public static var shared: DeveloperHooks {
        if let value = _shared {
            return value
        }
        assertionFailure("DeveloperHooks.install must be called before the developer screen is used")
        return .placeholder
    }

    public static func install(_ hooks: DeveloperHooks) {
        assert(Thread.isMainThread, "DeveloperHooks.install must be called on the main thread")
        _shared = hooks
    }

    public static let placeholder = DeveloperHooks()
}
