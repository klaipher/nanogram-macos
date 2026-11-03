import AppKit

public typealias NanogramLogCollector = () -> [URL]

public struct NanogramLogExportHooks {
    public var collect: (NanogramLogExportKind) -> NanogramLogCollector
    public var canSendInApp: () -> Bool
    public var sendToChat: (_ files: [URL], _ window: NSWindow?, _ completion: @escaping (Bool) -> Void) -> Void
    public var showProgress: (NSWindow?) -> () -> Void
    public var showMessage: (NSWindow?, String) -> Void

    public init(collect: @escaping (NanogramLogExportKind) -> NanogramLogCollector, canSendInApp: @escaping () -> Bool, sendToChat: @escaping (_ files: [URL], _ window: NSWindow?, _ completion: @escaping (Bool) -> Void) -> Void, showProgress: @escaping (NSWindow?) -> () -> Void, showMessage: @escaping (NSWindow?, String) -> Void) {
        self.collect = collect
        self.canSendInApp = canSendInApp
        self.sendToChat = sendToChat
        self.showProgress = showProgress
        self.showMessage = showMessage
    }

    private static var installed: NanogramLogExportHooks?

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
    private static let prepareQueue = DispatchQueue(label: "org.nanogram.log-export", qos: .userInitiated)
    private static var activeSharingDelegates: [NanogramLogSharingDelegate] = []

    public static var isRunning: Bool {
        return NanogramLogExportGate.shared.isRunning
    }

    public static func present(kind: NanogramLogExportKind, window: NSWindow?, anchor: NSView? = nil, collect: NanogramLogCollector? = nil, onDestinationChosen: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
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
        } else if let contentView = window?.contentView, let window = window {
            let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            menu.popUp(positioning: nil, at: point, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func perform(spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, collect: @escaping NanogramLogCollector, window: NSWindow?, anchor: NSView?) {
        let gate = NanogramLogExportGate.shared
        guard gate.begin() else {
            NSSound.beep()
            return
        }
        let hooks = NanogramLogExportHooks.shared
        let hideProgress = hooks.showProgress(window)
        prepareQueue.async {
            let root = NanogramLogExportFiles.defaultRoot()
            NanogramLogExportFiles.prune(root: root)
            let result: Result<[URL], Error>
            do {
                let directory = try NanogramLogExportFiles.makeDirectory(root: root)
                let files = try NanogramLogExportFiles.prepare(spec: spec, sources: collect(), in: directory)
                if files.isEmpty {
                    try? FileManager.default.removeItem(at: directory)
                }
                result = .success(files)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                hideProgress()
                switch result {
                case let .success(files) where !files.isEmpty:
                    deliver(files, spec: spec, destination: destination, window: window, anchor: anchor, finish: {
                        gate.end()
                    })
                case .success:
                    gate.end()
                    hooks.showMessage(window, "There are no \(spec.what.lowercased()) to send.")
                case let .failure(error):
                    gate.end()
                    hooks.showMessage(window, "Could not prepare \(spec.what.lowercased()): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func deliver(_ files: [URL], spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, window: NSWindow?, anchor: NSView?, finish: @escaping () -> Void) {
        let hooks = NanogramLogExportHooks.shared
        switch destination {
        case .nanogram:
            hooks.sendToChat(files, window, { sent in
                hooks.showMessage(window, sent ? "\(spec.what) sent." : "Could not send \(spec.what.lowercased()).")
            })
            finish()
        case .email:
            if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) {
                service.subject = spec.subject
                service.delegate = retainedDelegate(spec: spec, window: window, success: "\(spec.what) attached to a new email.")
                service.perform(withItems: files)
                finish()
            } else {
                showPicker(files, spec: spec, window: window, anchor: anchor)
                finish()
            }
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
            delegate.release?()
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    private static func saveToFolder(_ files: [URL], spec: NanogramLogExportSpec, window: NSWindow?, finish: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save"
        panel.message = "Choose a folder for \(spec.what.lowercased())."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else {
                finish()
                return
            }
            prepareQueue.async {
                var saved: [URL] = []
                var failure: Error?
                for file in files {
                    let target = folder.appendingPathComponent(file.lastPathComponent)
                    do {
                        if FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.removeItem(at: target)
                        }
                        try FileManager.default.copyItem(at: file, to: target)
                        saved.append(target)
                    } catch {
                        failure = error
                    }
                }
                DispatchQueue.main.async {
                    finish()
                    if let failure = failure {
                        NanogramLogExportHooks.shared.showMessage(window, "Could not save \(spec.what.lowercased()): \(failure.localizedDescription)")
                    } else {
                        NanogramLogExportHooks.shared.showMessage(window, "\(spec.what) saved to \(folder.lastPathComponent).")
                    }
                    if !saved.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(saved)
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
}

private final class NanogramLogMenuHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func choose(_ sender: Any?) {
        self.action()
    }
}

private final class NanogramLogSharingDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let spec: NanogramLogExportSpec
    private weak var window: NSWindow?
    private let success: String
    var release: (() -> Void)?

    init(spec: NanogramLogExportSpec, window: NSWindow?, success: String) {
        self.spec = spec
        self.window = window
        self.success = success
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

    private func finish() {
        let release = self.release
        self.release = nil
        release?()
    }
}
