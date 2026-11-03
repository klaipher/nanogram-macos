import AppKit
import NanogramDebug
import NanogramLogExport

public final class NanogramDebugWindowController: NSWindowController {
    private let settings: NanogramDebugSettings
    private var controls: [String: NSControl] = [:]
    private var observation: NanogramDebugObservation?
    private let stack = NSStackView()
    private var logButtons: [NanogramLogExportKind: NSButton] = [:]
    private let logProgress = NSProgressIndicator()
    private var gateObserver: NSObjectProtocol?

    public init(settings: NanogramDebugSettings = .shared) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Nanogram Debug Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        self.buildContent()
        self.observation = settings.observe { [weak self] _ in
            if Thread.isMainThread {
                self?.refreshValues()
            } else {
                DispatchQueue.main.async {
                    self?.refreshValues()
                }
            }
        }
        self.gateObserver = NotificationCenter.default.addObserver(forName: NanogramLogExportGate.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLogControls()
        }
        window.center()
    }

    deinit {
        if let gateObserver = self.gateObserver {
            NotificationCenter.default.removeObserver(gateObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func control(for id: String) -> NSControl? {
        return self.controls[id]
    }

    func logButton(for kind: NanogramLogExportKind) -> NSButton? {
        return self.logButtons[kind]
    }

    private func buildContent() {
        guard let window = self.window else {
            return
        }
        self.stack.orientation = .vertical
        self.stack.alignment = .leading
        self.stack.spacing = 8
        self.stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        self.stack.translatesAutoresizingMaskIntoConstraints = false

        let sections = self.settings.sections
        if sections.isEmpty {
            self.stack.addArrangedSubview(self.secondaryLabel("No switches are registered in this build."))
        }
        for (index, section) in sections.enumerated() {
            if index > 0 {
                self.stack.setCustomSpacing(18, after: self.stack.arrangedSubviews.last!)
            }
            let header = NSTextField(labelWithString: section.title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            self.stack.addArrangedSubview(header)
            for option in section.options {
                self.stack.addArrangedSubview(self.row(for: option))
                let notes = [option.detail, option.requiresRelaunch ? "Applies after relaunch." : nil].compactMap { $0 }
                if !notes.isEmpty {
                    self.stack.addArrangedSubview(self.secondaryLabel(notes.joined(separator: " ")))
                }
            }
        }

        let reset = NSButton(title: "Reset All", target: self, action: #selector(resetAll(_:)))
        self.stack.setCustomSpacing(18, after: self.stack.arrangedSubviews.last!)
        self.stack.addArrangedSubview(reset)

        self.stack.setCustomSpacing(18, after: reset)
        self.buildLogsSection()

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(self.stack)
        let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            self.stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            self.stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            self.stack.topAnchor.constraint(equalTo: document.topAnchor),
            self.stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        self.refreshValues()
    }

    private func buildLogsSection() {
        let header = NSTextField(labelWithString: "Logs")
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        self.stack.addArrangedSubview(header)
        self.stack.addArrangedSubview(self.secondaryLabel("Each export asks where to send it: a Nanogram chat, an email, another app, or a folder."))
        for kind in NanogramLogExportKind.allCases {
            let button = NSButton(title: NanogramLogExportSpec.current(kind).menuTitle + "…", target: self, action: #selector(sendLogs(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("logs." + kind.rawValue)
            self.logButtons[kind] = button
            self.stack.addArrangedSubview(button)
        }
        self.logProgress.style = .spinning
        self.logProgress.controlSize = .small
        self.logProgress.isDisplayedWhenStopped = false
        self.stack.addArrangedSubview(self.logProgress)
        self.refreshLogControls()
    }

    private func refreshLogControls() {
        let running = NanogramLogExport.isRunning
        for button in self.logButtons.values {
            button.isEnabled = !running
        }
        if running {
            self.logProgress.startAnimation(nil)
        } else {
            self.logProgress.stopAnimation(nil)
        }
    }

    @objc private func sendLogs(_ sender: NSButton) {
        guard let kind = self.logButtons.first(where: { $0.value === sender })?.key else {
            return
        }
        NanogramLogExport.present(kind: kind, window: self.window, anchor: sender)
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func row(for option: NanogramDebugOption) -> NSView {
        switch option.kind {
        case .toggle:
            let button = NSButton(checkboxWithTitle: option.title, target: self, action: #selector(toggleChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(option.id)
            self.controls[option.id] = button
            return button
        case let .choice(options, _):
            let label = NSTextField(labelWithString: option.title)
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: options.map { $0.title })
            popup.identifier = NSUserInterfaceItemIdentifier(option.id)
            popup.target = self
            popup.action = #selector(choiceChanged(_:))
            self.controls[option.id] = popup
            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
    }

    private func refreshValues() {
        for option in self.settings.options {
            guard let control = self.controls[option.id] else {
                continue
            }
            switch option.kind {
            case .toggle:
                (control as? NSButton)?.state = self.settings.bool(option.id) ? .on : .off
            case let .choice(options, _):
                if let value = self.settings.choice(option.id), let index = options.firstIndex(where: { $0.id == value }) {
                    (control as? NSPopUpButton)?.selectItem(at: index)
                }
            }
        }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else {
            return
        }
        self.settings.set(id, bool: sender.state == .on)
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let option = self.settings.option(id), case let .choice(options, _) = option.kind else {
            return
        }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < options.count else {
            return
        }
        self.settings.set(id, choice: options[index].id)
    }

    @objc private func resetAll(_ sender: Any?) {
        self.settings.resetAll()
        self.refreshValues()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        return true
    }
}
