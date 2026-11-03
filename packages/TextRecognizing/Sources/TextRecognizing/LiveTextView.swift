import AppKit
import QuartzCore
#if canImport(VisionKit)
import VisionKit

@available(macOS 13.0, *)
public final class LiveTextView: NSView, ImageAnalysisOverlayViewDelegate {
    public let overlayView = ImageAnalysisOverlayView()
    public var openCode: ((LiveTextCode) -> Void)?
    public var openLinkMenuTitle: String = "Open Link"
    public var codes: [LiveTextCode] = []
    public private(set) var result: LiveTextResult?
    private var subjectOverlay: CALayer?

    public var isActive: Bool = true {
        didSet {
            self.overlayView.isHidden = !self.isActive
            if !self.isActive {
                self.overlayView.resetSelection()
            }
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.overlayView.frame = self.bounds
        self.overlayView.autoresizingMask = [.width, .height]
        self.overlayView.delegate = self
        self.overlayView.preferredInteractionTypes = .automatic
        self.overlayView.setSupplementaryInterfaceHidden(true, animated: false)
        self.addSubview(self.overlayView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ result: LiveTextResult?) {
        self.result = result
        self.codes = result?.codes ?? []
        self.overlayView.analysis = result?.analysis
    }

    public var hasContent: Bool {
        return self.result?.hasContent ?? false
    }

    public var transcript: String {
        return self.result?.transcript ?? ""
    }

    public var hasSelectedText: Bool {
        return self.overlayView.hasActiveTextSelection
    }

    public var selectedText: String? {
        guard self.overlayView.hasActiveTextSelection else {
            return nil
        }
        if #available(macOS 14.0, *) {
            let text = self.overlayView.selectedText
            return text.isEmpty ? nil : text
        }
        return nil
    }

    public func resetSelection() {
        self.overlayView.resetSelection()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isActive, !self.isHidden, self.result != nil else {
            return nil
        }
        let local = self.superview.map { self.convert(point, from: $0) } ?? point
        guard self.bounds.contains(local) else {
            return nil
        }
        let hit = super.hitTest(point)
        if let hit, LiveTextView.isOverlayControl(hit, in: self) {
            return hit
        }
        let overlayPoint = self.overlayView.convert(local, from: self)
        guard self.overlayView.hasInteractiveItem(at: overlayPoint) || self.overlayView.hasActiveTextSelection else {
            return nil
        }
        return hit === self ? self.overlayView : hit
    }

    private static func isOverlayControl(_ view: NSView, in container: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current, candidate !== container {
            if candidate is NSControl {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    public func normalizedPoint(fromWindow point: NSPoint) -> CGPoint? {
        let point = self.convert(point, from: nil)
        guard self.frame.width > 0, self.frame.height > 0, NSPointInRect(point, self.bounds) else {
            return nil
        }
        return CGPoint(x: point.x / self.frame.width, y: point.y / self.frame.height)
    }

    public func code(atViewPoint point: CGPoint) -> LiveTextCode? {
        guard self.bounds.width > 0, self.bounds.height > 0 else {
            return nil
        }
        let y = self.isFlipped ? self.bounds.height - point.y : point.y
        return LiveTextCodes.code(at: CGPoint(x: point.x / self.bounds.width, y: y / self.bounds.height), in: self.codes)
    }

    public func code(atWindow point: NSPoint) -> LiveTextCode? {
        guard self.isActive, !self.isHidden else {
            return nil
        }
        let local = self.convert(point, from: nil)
        guard self.bounds.contains(local) else {
            return nil
        }
        return self.code(atViewPoint: local)
    }

    private func code(atOverlayPoint point: CGPoint) -> LiveTextCode? {
        return self.code(atViewPoint: self.overlayView.convert(point, to: self))
    }

    public func shouldBeginInteraction(at point: CGPoint, types: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        if types.contains(.dataDetectors), let code = self.code(atOverlayPoint: point) {
            self.openCode?(code)
            return false
        }
        return true
    }

    public func contentsRect() -> CGRect {
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    public func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint, forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        return self.shouldBeginInteraction(at: point, types: analysisType)
    }

    public func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        return self.contentsRect()
    }

    @available(macOS 14.0, *)
    public func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu, for event: NSEvent, at point: CGPoint) -> NSMenu {
        if let link = self.code(atOverlayPoint: point)?.link {
            let item = NSMenuItem(title: self.openLinkMenuTitle, action: #selector(self.openMenuLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = link
            menu.insertItem(item, at: 0)
            menu.insertItem(NSMenuItem.separator(), at: 1)
        }
        return menu
    }

    @objc private func openMenuLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String, let code = self.codes.first(where: { $0.link == link }) {
            self.openCode?(code)
        }
    }

    public func showLiftedSubject(_ image: CGImage, rect: CGRect, completion: @escaping () -> Void) {
        self.subjectOverlay?.removeFromSuperlayer()
        guard let layer = self.layer else {
            completion()
            return
        }
        let container = CALayer()
        container.frame = self.bounds

        let dim = CALayer()
        dim.frame = self.bounds
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        container.addSublayer(dim)

        let subject = CALayer()
        subject.frame = CGRect(x: rect.minX * self.bounds.width, y: rect.minY * self.bounds.height, width: rect.width * self.bounds.width, height: rect.height * self.bounds.height)
        subject.contents = image
        subject.contentsGravity = .resize
        subject.shadowColor = NSColor.white.cgColor
        subject.shadowRadius = 10
        subject.shadowOffset = .zero
        subject.shadowOpacity = 0.6
        container.addSublayer(subject)

        layer.addSublayer(container)
        self.subjectOverlay = container

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        dim.add(fade, forKey: "fade")

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.04
        scale.damping = 12
        scale.duration = 0.4
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        subject.add(scale, forKey: "scale")

        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0, 0.95, 0.6]
        glow.keyTimes = [0, 0.35, 1]
        glow.duration = 0.7
        subject.add(glow, forKey: "glow")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self, weak container] in
            guard let container = container else {
                return
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak container] in
                container?.removeFromSuperlayer()
                if let self = self, self.subjectOverlay === container {
                    self.subjectOverlay = nil
                }
            }
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1
            out.toValue = 0
            out.duration = 0.25
            out.fillMode = .forwards
            out.isRemovedOnCompletion = false
            container.add(out, forKey: "out")
            CATransaction.commit()
            completion()
        }
    }
}
#endif
