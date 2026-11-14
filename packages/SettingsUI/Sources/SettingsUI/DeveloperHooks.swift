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

public struct DeveloperSwitch {
    public let isOn: () -> Bool
    public let setOn: (Bool) -> Void

    public init(isOn: @escaping () -> Bool, setOn: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.setOn = setOn
    }
}

public struct DeveloperOption {
    public enum Kind {
        case toggle(isOn: Bool, set: (Bool) -> Void)
        case choice(titles: [String], selected: Int, select: (Int) -> Void)
    }

    public let id: String
    public let title: String
    public let footnote: String?
    public let kind: Kind

    public init(id: String, title: String, footnote: String?, kind: Kind) {
        self.id = id
        self.title = title
        self.footnote = footnote
        self.kind = kind
    }
}

public struct DeveloperOptionSection {
    public let title: String
    public let options: [DeveloperOption]

    public init(title: String, options: [DeveloperOption]) {
        self.title = title
        self.options = options
    }
}

public struct DeveloperHooks {
    public let nanogramSections: (() -> [DeveloperOptionSection])?
    public let resetNanogramSections: (() -> Void)?
    public let messageWidgets: DeveloperSwitch?
    public let logExports: [DeveloperLogExport]
    public let sendLogs: ((NSWindow?) -> Void)?

    public init(nanogramSections: (() -> [DeveloperOptionSection])? = nil, resetNanogramSections: (() -> Void)? = nil, messageWidgets: DeveloperSwitch? = nil, logExports: [DeveloperLogExport] = [], sendLogs: ((NSWindow?) -> Void)? = nil) {
        self.nanogramSections = nanogramSections
        self.resetNanogramSections = resetNanogramSections
        self.messageWidgets = messageWidgets
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
