import AppKit

public typealias NanogramLogCollector = @Sendable () -> [URL]

public struct NanogramLogExportHooks: Sendable {
    public var collect: @MainActor @Sendable (NanogramLogExportKind) -> NanogramLogCollector
    public var canSendInApp: @MainActor @Sendable () -> Bool
    public var sendToChat: @MainActor @Sendable (_ files: [URL], _ window: NSWindow?, _ completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Void
    public var showProgress: @MainActor @Sendable (NSWindow?) -> @MainActor @Sendable () -> Void
    public var showMessage: @MainActor @Sendable (NSWindow?, String) -> Void

    public init(collect: @escaping @MainActor @Sendable (NanogramLogExportKind) -> NanogramLogCollector, canSendInApp: @escaping @MainActor @Sendable () -> Bool, sendToChat: @escaping @MainActor @Sendable (_ files: [URL], _ window: NSWindow?, _ completion: @escaping @MainActor @Sendable (Bool) -> Void) -> Void, showProgress: @escaping @MainActor @Sendable (NSWindow?) -> @MainActor @Sendable () -> Void, showMessage: @escaping @MainActor @Sendable (NSWindow?, String) -> Void) {
        self.collect = collect
        self.canSendInApp = canSendInApp
        self.sendToChat = sendToChat
        self.showProgress = showProgress
        self.showMessage = showMessage
    }

    nonisolated(unsafe) private static var installed: NanogramLogExportHooks?

    public static var shared: NanogramLogExportHooks {
        return installed ?? .standalone
    }

    public static func install(_ hooks: NanogramLogExportHooks) {
        precondition(Thread.isMainThread)
        installed = hooks
    }

    public static let standalone = NanogramLogExportHooks(collect: { _ in
        return { [] }
    }, canSendInApp: {
        return false
    }, sendToChat: { _, _, completion in
        completion(false)
    }, showProgress: { _ in
        return {}
    }, showMessage: { window, text in
        let alert = NSAlert()
        alert.messageText = text
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    })
}

public enum NanogramLogExport {
    public static func present(kind: NanogramLogExportKind, window: NSWindow?, anchor: NSView? = nil, collect: NanogramLogCollector? = nil, onDestinationChosen: (@MainActor @Sendable () -> Void)? = nil) {
        DispatchQueue.main.async {
            NanogramLogExportFlow.present(kind: kind, window: window, anchor: anchor, collect: collect, onDestinationChosen: onDestinationChosen)
        }
    }

    @MainActor
    public static var isRunning: Bool {
        return NanogramLogExportGate.shared.isRunning
    }
}

private enum NanogramLogExportOutcome: Sendable {
    case files([URL])
    case nothing
    case failed(String)
}

@MainActor
private enum NanogramLogExportFlow {
    nonisolated private static let workQueue = DispatchQueue(label: "org.nanogram.log-export", qos: .userInitiated)
    private static var activeSharingDelegates: [NanogramLogSharingDelegate] = []

    static func present(kind: NanogramLogExportKind, window: NSWindow?, anchor: NSView?, collect: NanogramLogCollector?, onDestinationChosen: (@MainActor @Sendable () -> Void)?) {
        if NanogramLogExportGate.shared.isRunning {
            NSSound.beep()
            return
        }
        let hooks = NanogramLogExportHooks.shared
        let spec = NanogramLogExportSpec.current(kind)
        let collector = collect ?? hooks.collect(kind)
        let menu = NSMenu(title: spec.menuTitle)
        menu.autoenablesItems = false
        let header = NSMenuItem(title: spec.menuTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for destination in nanogramLogExportDestinations(canSendInApp: hooks.canSendInApp()) {
            let handler = NanogramLogMenuHandler {
                onDestinationChosen?()
                perform(spec: spec, destination: destination, collect: collector, window: window, anchor: anchor)
            }
            let item = NSMenuItem(title: destination.title, action: #selector(NanogramLogMenuHandler.choose(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        popUp(menu, window: window, anchor: anchor)
    }

    private static func popUp(_ menu: NSMenu, window: NSWindow?, anchor: NSView?) {
        if let anchor = anchor, anchor.window != nil {
            let y = anchor.isFlipped ? anchor.bounds.height + 4 : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchor)
        } else if let window = window, let contentView = window.contentView {
            let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            menu.popUp(positioning: nil, at: point, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private static func perform(spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, collect: @escaping NanogramLogCollector, window: NSWindow?, anchor: NSView?) {
        let gate = NanogramLogExportGate.shared
        guard gate.begin() else {
            NSSound.beep()
            return
        }
        let hideProgress = NanogramLogExportHooks.shared.showProgress(window)
        workQueue.async {
            let outcome = prepare(spec: spec, collect: collect)
            DispatchQueue.main.async {
                hideProgress()
                let showMessage = NanogramLogExportHooks.shared.showMessage
                switch outcome {
                case let .files(files):
                    deliver(files, spec: spec, destination: destination, window: window, anchor: anchor, finish: {
                        gate.end()
                    })
                case .nothing:
                    gate.end()
                    showMessage(window, "There are no \(spec.what.lowercased()) to send.")
                case let .failed(reason):
                    gate.end()
                    showMessage(window, "Could not prepare \(spec.what.lowercased()): \(reason)")
                }
            }
        }
    }

    nonisolated private static func prepare(spec: NanogramLogExportSpec, collect: NanogramLogCollector) -> NanogramLogExportOutcome {
        let root = NanogramLogExportFiles.defaultRoot()
        NanogramLogExportFiles.prune(root: root)
        do {
            let directory = try NanogramLogExportFiles.makeDirectory(root: root)
            let files = try NanogramLogExportFiles.prepare(spec: spec, sources: collect(), in: directory)
            if files.isEmpty {
                try? FileManager.default.removeItem(at: directory)
                return .nothing
            }
            return .files(files)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func deliver(_ files: [URL], spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, window: NSWindow?, anchor: NSView?, finish: @escaping @MainActor () -> Void) {
        let hooks = NanogramLogExportHooks.shared
        switch destination {
        case .nanogram:
            hooks.sendToChat(files, window, { sent in
                NanogramLogExportHooks.shared.showMessage(window, sent ? "\(spec.what) sent." : "Could not send \(spec.what.lowercased()).")
            })
            finish()
        case .email:
            if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) {
                service.subject = spec.subject
                service.delegate = retainedDelegate(spec: spec, window: window, success: "\(spec.what) attached to a new email.")
                service.perform(withItems: files)
            } else {
                showPicker(files, spec: spec, window: window, anchor: anchor)
            }
            finish()
        case .otherApps:
            showPicker(files, spec: spec, window: window, anchor: anchor)
            finish()
        case .saveToFolder:
            saveToFolder(files, spec: spec, window: window, finish: finish)
        }
    }

    private static func retainedDelegate(spec: NanogramLogExportSpec, window: NSWindow?, success: String) -> NanogramLogSharingDelegate {
        let delegate = NanogramLogSharingDelegate(spec: spec, window: window, success: success)
        delegate.release = { [weak delegate] in
            activeSharingDelegates.removeAll(where: { $0 === delegate })
        }
        activeSharingDelegates.append(delegate)
        return delegate
    }

    private static func showPicker(_ files: [URL], spec: NanogramLogExportSpec, window: NSWindow?, anchor: NSView?) {
        let picker = NSSharingServicePicker(items: files)
        let delegate = retainedDelegate(spec: spec, window: window, success: "\(spec.what) shared.")
        picker.delegate = delegate
        if let anchor = anchor, anchor.window != nil {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let window = window, let contentView = window.contentView {
            let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: contentView, preferredEdge: .minY)
        } else {
            delegate.finish()
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    private static func saveToFolder(_ files: [URL], spec: NanogramLogExportSpec, window: NSWindow?, finish: @escaping @MainActor () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save"
        panel.message = "Choose a folder for \(spec.what.lowercased())."
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else {
                finish()
                return
            }
            workQueue.async {
                let result = copy(files, to: folder)
                DispatchQueue.main.async {
                    finish()
                    let showMessage = NanogramLogExportHooks.shared.showMessage
                    if let failure = result.failure {
                        showMessage(window, "Could not save \(spec.what.lowercased()): \(failure)")
                    } else {
                        showMessage(window, "\(spec.what) saved to \(folder.lastPathComponent).")
                    }
                    if !result.saved.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(result.saved)
                    }
                }
            }
        }
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    nonisolated private static func copy(_ files: [URL], to folder: URL) -> (saved: [URL], failure: String?) {
        var saved: [URL] = []
        var failure: String?
        for file in files {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: file, to: target)
                saved.append(target)
            } catch {
                failure = error.localizedDescription
            }
        }
        return (saved, failure)
    }
}

@MainActor
private final class NanogramLogMenuHandler: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func choose(_ sender: Any?) {
        self.action()
    }
}

@MainActor
private final class NanogramLogSharingDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let spec: NanogramLogExportSpec
    private weak var window: NSWindow?
    private let success: String
    var release: (@MainActor () -> Void)?

    init(spec: NanogramLogExportSpec, window: NSWindow?, success: String) {
        self.spec = spec
        self.window = window
        self.success = success
    }

    func finish() {
        let release = self.release
        self.release = nil
        release?()
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        return self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil {
            self.finish()
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        NanogramLogExportHooks.shared.showMessage(self.window, self.success)
        self.finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let nsError = error as NSError
        if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
            NanogramLogExportHooks.shared.showMessage(self.window, "Could not share \(self.spec.what.lowercased()): \(error.localizedDescription)")
        }
        self.finish()
    }
}
