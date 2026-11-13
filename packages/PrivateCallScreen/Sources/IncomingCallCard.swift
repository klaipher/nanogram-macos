import AppKit
import Localization

private final class IncomingCallPanel: NSPanel {
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

private final class IncomingCallCardButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

private final class IncomingCallCardAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func fire() {
        self.handler()
    }
}

final class IncomingCallCard {
    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let acceptAction: IncomingCallCardAction
    private let declineAction: IncomingCallCardAction

    init(accept: @escaping () -> Void, decline: @escaping () -> Void) {
        let size = IncomingCallPanelConfiguration.size
        let panel = IncomingCallPanel(contentRect: NSMakeRect(0, 0, size.width, size.height), styleMask: IncomingCallPanelConfiguration.styleMask, backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = IncomingCallPanelConfiguration.level
        panel.collectionBehavior = IncomingCallPanelConfiguration.collectionBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView(frame: NSMakeRect(0, 0, size.width, size.height))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        let iconView = NSImageView(frame: NSMakeRect(16, (size.height - 56) / 2, 56, 56))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        background.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSMakeRect(84, size.height - 40, size.width - 84 - 16, 20)
        background.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSMakeRect(84, size.height - 60, size.width - 84 - 16, 16)
        background.addSubview(subtitleLabel)

        let acceptAction = IncomingCallCardAction(accept)
        let declineAction = IncomingCallCardAction(decline)

        let buttonWidth: CGFloat = (size.width - 84 - 16 - 8) / 2
        let declineButton = IncomingCallCard.makeButton(title: L10n.callDecline, color: .systemRed, action: declineAction)
        declineButton.frame = NSMakeRect(84, 12, buttonWidth, 28)
        background.addSubview(declineButton)
        let acceptButton = IncomingCallCard.makeButton(title: L10n.callAccept, color: .systemGreen, action: acceptAction)
        acceptButton.frame = NSMakeRect(84 + buttonWidth + 8, 12, buttonWidth, 28)
        background.addSubview(acceptButton)

        self.panel = panel
        self.titleLabel = titleLabel
        self.subtitleLabel = subtitleLabel
        self.acceptAction = acceptAction
        self.declineAction = declineAction
    }

    private static func makeButton(title: String, color: NSColor, action: IncomingCallCardAction) -> NSButton {
        let button = IncomingCallCardButton(title: title, target: action, action: #selector(IncomingCallCardAction.fire))
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 8
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        return button
    }

    var isVisible: Bool {
        return self.panel.isVisible
    }

    func update(title: String, subtitle: String) {
        self.titleLabel.stringValue = title
        self.subtitleLabel.stringValue = subtitle
    }

    func show() {
        if !self.panel.isVisible {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let frame = screen?.visibleFrame {
                self.panel.setFrameOrigin(IncomingCallPanelConfiguration.origin(in: frame))
            }
        }
        self.panel.orderFrontRegardless()
    }

    func hide() {
        self.panel.orderOut(nil)
    }
}
