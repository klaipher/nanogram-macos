import AppKit

public typealias NanogramLogCollector = @Sendable () -> [URL]
public typealias NanogramLogChatSendCompletion = @MainActor @Sendable (NanogramLogChatSendResult) -> Void

public struct NanogramLogExportHooks: Sendable {
    public var collect: @MainActor @Sendable (NanogramLogExportKind) -> NanogramLogCollector
    public var canSendInApp: @MainActor @Sendable () -> Bool
    public var sendToChat: @MainActor @Sendable (_ files: [URL], _ window: NSWindow?, _ completion: @escaping NanogramLogChatSendCompletion) -> Void
    public var showProgress: @MainActor @Sendable (NSWindow?) -> @MainActor @Sendable () -> Void
    public var showMessage: @MainActor @Sendable (NSWindow?, String) -> Void
    public var availableKinds: @MainActor @Sendable () -> [NanogramLogExportKind]

    public init(collect: @escaping @MainActor @Sendable (NanogramLogExportKind) -> NanogramLogCollector, canSendInApp: @escaping @MainActor @Sendable () -> Bool, sendToChat: @escaping @MainActor @Sendable (_ files: [URL], _ window: NSWindow?, _ completion: @escaping NanogramLogChatSendCompletion) -> Void, showProgress: @escaping @MainActor @Sendable (NSWindow?) -> @MainActor @Sendable () -> Void, showMessage: @escaping @MainActor @Sendable (NSWindow?, String) -> Void, availableKinds: @escaping @MainActor @Sendable () -> [NanogramLogExportKind] = { NanogramLogExportKind.allCases }) {
        self.collect = collect
        self.canSendInApp = canSendInApp
        self.sendToChat = sendToChat
        self.showProgress = showProgress
        self.showMessage = showMessage
        self.availableKinds = availableKinds
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
        completion(.failed)
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
    public static func present(kind: NanogramLogExportKind, window: NSWindow?, anchor: NSView? = nil, collect: NanogramLogCollector? = nil, onDelivered: (@MainActor @Sendable () -> Void)? = nil) {
        DispatchQueue.main.async {
            NanogramLogExportFlow.present(kind: kind, window: window, anchor: anchor, collect: collect, onDelivered: onDelivered)
        }
    }

    @MainActor
    public static var isRunning: Bool {
        return NanogramLogExportGate.shared.isRunning
    }

    @MainActor
    public static var availableKinds: [NanogramLogExportKind] {
        let available = NanogramLogExportHooks.shared.availableKinds()
        return NanogramLogExportKind.allCases.filter { available.contains($0) }
    }
}

private enum NanogramLogExportOutcome: Sendable {
    case files([URL], directory: URL)
    case nothing
    case failed(String)
}

@MainActor
enum NanogramLogExportFlow {
    nonisolated private static let workQueue = DispatchQueue(label: "org.nanogram.log-export", qos: .userInitiated)
    private static var activeSharingDelegates: [NanogramLogSharingDelegate] = []

    static func present(kind: NanogramLogExportKind, window: NSWindow?, anchor: NSView?, collect: NanogramLogCollector?, onDelivered: (@MainActor @Sendable () -> Void)?) {
        if NanogramLogExportGate.shared.isRunning {
            NSSound.beep()
            return
        }
        let hooks = NanogramLogExportHooks.shared
        let spec = NanogramLogExportSpec.current(kind)
        guard hooks.availableKinds().contains(kind) else {
            hooks.showMessage(window, spec.unavailableText)
            return
        }
        let collector = collect ?? hooks.collect(kind)
        let root = NanogramLogExportFiles.defaultRoot()
        let menu = NSMenu(title: spec.menuTitle)
        menu.autoenablesItems = false
        let header = NSMenuItem(title: spec.menuTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for destination in nanogramLogExportDestinations(canSendInApp: hooks.canSendInApp()) {
            let handler = NanogramLogMenuHandler {
                perform(spec: spec, destination: destination, collect: collector, window: window, anchor: anchor, root: root, onDelivered: onDelivered)
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

    static func perform(spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, collect: @escaping NanogramLogCollector, window: NSWindow?, anchor: NSView?, root: URL, onDelivered: (@MainActor @Sendable () -> Void)?) {
        guard let run = NanogramLogExportRun(gate: NanogramLogExportGate.shared, onDelivered: onDelivered) else {
            NSSound.beep()
            return
        }
        let hideProgress = NanogramLogExportHooks.shared.showProgress(window)
        workQueue.async {
            let outcome = prepare(spec: spec, collect: collect, root: root)
            DispatchQueue.main.async {
                hideProgress()
                let showMessage = NanogramLogExportHooks.shared.showMessage
                switch outcome {
                case let .files(files, directory):
                    run.attach(directory: directory)
                    deliver(files, spec: spec, destination: destination, window: window, anchor: anchor, run: run)
                case .nothing:
                    run.finish(delivered: false)
                    showMessage(window, "There are no \(spec.what.lowercased()) to send.") //TODOLANG
                case let .failed(reason):
                    run.finish(delivered: false)
                    showMessage(window, "Could not prepare \(spec.what.lowercased()): \(reason)") //TODOLANG
                }
            }
        }
    }

    nonisolated private static func prepare(spec: NanogramLogExportSpec, collect: NanogramLogCollector, root: URL) -> NanogramLogExportOutcome {
        NanogramLogExportFiles.prune(root: root)
        let directory: URL
        do {
            directory = try NanogramLogExportFiles.makeDirectory(root: root)
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            let files = try NanogramLogExportFiles.prepare(spec: spec, sources: collect(), in: directory)
            if files.isEmpty {
                try? FileManager.default.removeItem(at: directory)
                return .nothing
            }
            return .files(files, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .failed(error.localizedDescription)
        }
    }

    private static func deliver(_ files: [URL], spec: NanogramLogExportSpec, destination: NanogramLogExportDestination, window: NSWindow?, anchor: NSView?, run: NanogramLogExportRun) {
        switch destination {
        case .nanogram:
            NanogramLogExportHooks.shared.sendToChat(files, window, { result in
                guard !run.isFinished else {
                    return
                }
                let showMessage = NanogramLogExportHooks.shared.showMessage
                switch result {
                case .cancelled:
                    run.finish(delivered: false)
                case .sent:
                    run.finish(delivered: true)
                    showMessage(window, "\(spec.what) sent.") //TODOLANG
                case .failed:
                    run.finish(delivered: false)
                    showMessage(window, "Could not send \(spec.what.lowercased()).") //TODOLANG
                }
            })
        case .email:
            let hasMailApp = URL(string: "mailto:").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
            if let service = NSSharingService(named: .composeEmail), nanogramLogEmailRoute(hasMailApp: hasMailApp, canCompose: service.canPerform(withItems: files)) == .compose {
                service.subject = spec.subject
                service.delegate = retainedDelegate(run: run, spec: spec, window: window, success: "\(spec.what) attached to a new email.", fallback: { //TODOLANG
                    showPicker(files, spec: spec, window: window, anchor: anchor, run: run)
                })
                service.perform(withItems: files)
            } else {
                showPicker(files, spec: spec, window: window, anchor: anchor, run: run)
            }
        case .otherApps:
            showPicker(files, spec: spec, window: window, anchor: anchor, run: run)
        case .saveToFolder:
            saveToFolder(files, spec: spec, window: window, run: run)
        }
    }

    private static func retainedDelegate(run: NanogramLogExportRun, spec: NanogramLogExportSpec, window: NSWindow?, success: String, fallback: (@MainActor () -> Void)? = nil) -> NanogramLogSharingDelegate {
        let delegate = NanogramLogSharingDelegate(run: run, spec: spec, window: window, success: success, fallback: fallback)
        delegate.release = { [weak delegate] in
            activeSharingDelegates.removeAll(where: { $0 === delegate })
        }
        activeSharingDelegates.append(delegate)
        return delegate
    }

    private static func showPicker(_ files: [URL], spec: NanogramLogExportSpec, window: NSWindow?, anchor: NSView?, run: NanogramLogExportRun) {
        let picker = NSSharingServicePicker(items: files)
        let delegate = retainedDelegate(run: run, spec: spec, window: window, success: "\(spec.what) shared.") //TODOLANG
        picker.delegate = delegate
        let host = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let anchor = anchor, anchor.window != nil {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let host = host, let contentView = host.contentView {
            let point = contentView.convert(host.mouseLocationOutsideOfEventStream, from: nil)
            picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: contentView, preferredEdge: .minY)
        } else {
            delegate.end(delivered: false, removeFiles: false)
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    private static func saveToFolder(_ files: [URL], spec: NanogramLogExportSpec, window: NSWindow?, run: NanogramLogExportRun) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save" //TODOLANG
        panel.message = "Choose a folder for \(spec.what.lowercased())." //TODOLANG
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else {
                run.finish(delivered: false)
                return
            }
            workQueue.async {
                let result = copy(files, to: folder)
                DispatchQueue.main.async {
                    run.finish(delivered: result.failure == nil && !result.saved.isEmpty)
                    let showMessage = NanogramLogExportHooks.shared.showMessage
                    if let failure = result.failure {
                        showMessage(window, "Could not save \(spec.what.lowercased()): \(failure)") //TODOLANG
                    } else {
                        showMessage(window, "\(spec.what) saved to \(folder.lastPathComponent).") //TODOLANG
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
    private let run: NanogramLogExportRun
    private let spec: NanogramLogExportSpec
    private weak var window: NSWindow?
    private let success: String
    private var fallback: (@MainActor () -> Void)?
    var release: (@MainActor () -> Void)?

    init(run: NanogramLogExportRun, spec: NanogramLogExportSpec, window: NSWindow?, success: String, fallback: (@MainActor () -> Void)?) {
        self.run = run
        self.spec = spec
        self.window = window
        self.success = success
        self.fallback = fallback
    }

    func end(delivered: Bool, removeFiles: Bool = true) {
        self.run.finish(delivered: delivered, removeFiles: removeFiles)
        self.detach()
    }

    private func detach() {
        let release = self.release
        self.release = nil
        release?()
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        return self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil {
            self.end(delivered: false)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        self.end(delivered: true)
        NanogramLogExportHooks.shared.showMessage(self.window, self.success)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        if let fallback = self.fallback, nanogramLogEmailFailureOffersPicker(error) {
            self.fallback = nil
            self.detach()
            fallback()
            return
        }
        let nsError = error as NSError
        if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
            NanogramLogExportHooks.shared.showMessage(self.window, "Could not share \(self.spec.what.lowercased()): \(error.localizedDescription)") //TODOLANG
        }
        self.end(delivered: false)
    }
}
