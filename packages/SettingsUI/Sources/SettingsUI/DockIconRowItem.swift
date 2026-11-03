import Cocoa
import TGUIKit
import TelegramCore
import SwiftSignalKit
import Postbox
import GeneralRows
import Localization
import TelegramContext
import TelegramUtils
import TelegramTheme
import ColorPalette
import FoundationUtils
import InputDataUI
import TelegramIconsTheme
import AlertsUI
import InAppSettings
import ApiCredentials
import TelegramMediaUtils
import NanogramAppIcons


public struct DockIconData {
    public let icon: NanogramAppIcon
    public let selected: Bool
    public let frame: NSRect

}

private func dockIconThumbnail(_ icon: NanogramAppIcon, size: NSSize, scale: CGFloat) -> CGImage? {
    var rect = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    return icon.image()?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}



public final class DockIconRowItem: GeneralRowItem {
    private(set) var wallpaperImage: CGImage?
    public let icons: [DockIconData]
    public let context: any AccountContextProtocol
    public let callback: (NanogramAppIcon)->Void
    public init(_ initialSize: NSSize, stableId: AnyHashable, viewType: GeneralViewType, context: any AccountContextProtocol, dockIcons: [NanogramAppIcon], selected: String?, action: @escaping(NanogramAppIcon)->Void, insets: NSEdgeInsets = NSEdgeInsetsMake(0, 20, 0, 20)) {
        self.context = context
        self.callback = action
        var icons: [DockIconData] = []
        var frame: CGRect = CGRect(origin: CGPointMake(20, 20), size: DockIconRowItem.iconSize)
        let selectedIcon = NanogramAppIcon.selected(storedName: selected)
        for (i, icon) in dockIcons.enumerated() {
            icons.append(DockIconData(icon: icon, selected: icon == selectedIcon, frame: frame))
            frame.origin.x += DockIconRowItem.iconSize.width
            if (i + 1) % Int(DockIconRowItem.rowCount) == 0 {
                frame.origin.y += DockIconRowItem.iconSize.height
                frame.origin.x = 20
            }
        }
        
        self.icons = icons
        
        
        super.init(initialSize, stableId: stableId, viewType: viewType, inset: insets)
        
        self.wallpaperImage = nil

    }
    
    public override func viewClass() -> AnyClass {
        return DockIconRowView.self
    }
    
    public override var accessibilityLabel: String? {
        return strings().appearanceSettingsDockIcon
    }
    
    public var containerSize: NSSize {
        return NSMakeSize(DockIconRowItem.rowCount * DockIconRowItem.iconSize.width + 40, ceil(CGFloat(icons.count) / DockIconRowItem.rowCount) * DockIconRowItem.iconSize.height + 30)
    }
    
    public static var iconSize: NSSize {
        return NSMakeSize(60, 70)
    }
    public static var rowCount: CGFloat {
        return 4.0
    }
    
    public override var height: CGFloat {
        var height: CGFloat = 20
        
        height += containerSize.height
        
        height += 20
        return height
    }
}

private final class DockIconView : Control {
    
    private let content = SimpleLayer()
    private let selected = SimpleLayer()
    private let selectionOutline = SimpleLayer()
    
    private var item: DockIconData?
    private weak var rowItem: DockIconRowItem?
    
    override func accessibilityLabel() -> String? {
        return item?.icon.title ?? strings().appearanceSettingsDockIcon
    }
    
    override func isAccessibilitySelected() -> Bool {
        return item?.selected ?? false
    }
    
    private let imageDisposable = MetaDisposable()
    
    public required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.frame = NSMakeRect(0, 0, 60, 60)
        self.layer?.addSublayer(content)
        self.layer?.addSublayer(selectionOutline)
        self.layer?.addSublayer(selected)
        
        
        selectionOutline.frame = content.frame.insetBy(dx: 2, dy: 2)
        selectionOutline.cornerRadius = 14
        selectionOutline.borderWidth = 2
        selectionOutline.opacity = 0

        selected.frame = NSMakeRect(0, 0, 6, 6)
        selected.cornerRadius = selected.frame.height / 2.0
        selected.opacity = 0
        
        set(handler: { [weak self] _ in
            if let rowItem = self?.rowItem, let item = self?.item, !item.selected {
                rowItem.callback(item.icon)
            }
        }, for: .Click)
        
        self.layer?.masksToBounds = false
    }
    
    public override func layout() {
        super.layout()
        self.selected.frame = CGRect(origin: NSMakePoint((frame.width - selected.frame.width) / 2, content.frame.maxY), size: selected.frame.size)
    }

    public override func stateDidUpdate(_ state: ControlState) {
        scaleOnClick = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.stateDidUpdate(state)
    }
    
    public func set(item: DockIconData, rowItem: DockIconRowItem, animated: Bool) {
       
        let sameIcon = self.item?.icon == item.icon
        self.item = item
        self.rowItem = rowItem
        self.toolTip = item.icon.title
        
        if !sameIcon {
            self.content.contents = nil
            let icon = item.icon
            let size = content.frame.size
            let scale = System.backingScale
            let signal: Signal<CGImage?, NoError> = Signal { subscriber in
                subscriber.putNext(dockIconThumbnail(icon, size: size, scale: scale))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            |> runOn(.concurrentDefaultQueue())
            |> deliverOnMainQueue
            
            imageDisposable.set(signal.start(next: { [weak self] image in
                guard let self, self.item?.icon == icon else {
                    return
                }
                self.content.contents = image
                self.content.animateContents()
            }))
        }
        self.updateSelection(item.selected, animated: animated && sameIcon)
    }

    private func updateSelection(_ isSelected: Bool, animated: Bool) {
        selected.backgroundColor = theme.colors.accent.cgColor
        selectionOutline.borderColor = theme.colors.accent.cgColor

        let opacity: Float = isSelected ? 1 : 0
        let previousOpacity = selected.presentation()?.opacity ?? selected.opacity
        let selectionChanged = selected.opacity != opacity
        selected.opacity = opacity
        selectionOutline.opacity = opacity

        if animated && selectionChanged {
            selected.animateAlpha(from: CGFloat(previousOpacity), to: CGFloat(opacity), duration: 0.18)
            selectionOutline.animateAlpha(from: CGFloat(previousOpacity), to: CGFloat(opacity), duration: 0.18)
            if isSelected && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                selectionOutline.animateScale(from: 0.94, to: 1, duration: 0.2, timingFunction: .easeOut)
            } else {
                selectionOutline.removeAnimation(forKey: "transform.scale")
            }
        } else if !animated {
            selected.removeAllAnimations()
            selectionOutline.removeAllAnimations()
        }
    }
    
    deinit {
        imageDisposable.dispose()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private class Container : NSVisualEffectView {
    public override var isFlipped: Bool {
        return true
    }
}

public final class DockIconRowView : GeneralContainableRowView {
    private let backgroundView = BackgroundView(frame: .zero)
    private let visualEffect = Container()
    
    public required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(backgroundView)
        addSubview(visualEffect)
        
        visualEffect.wantsLayer = true
        visualEffect.state = .active
        visualEffect.blendingMode = .withinWindow
        visualEffect.autoresizingMask = []
        visualEffect.material = .light
        
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.borderWidth = 1
        
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layout() {
        super.layout()
        guard let item = item as? DockIconRowItem else {
            return
        }
        backgroundView.frame = containerView.bounds
        visualEffect.frame = containerView.focus(item.containerSize)
    }
    
    public override func set(item: TableRowItem, animated: Bool = false) {
        super.set(item: item, animated: animated)
        
        guard let item = item as? DockIconRowItem else {
            return
        }
        
        while visualEffect.subviews.count > item.icons.count {
            visualEffect.subviews.last?.removeFromSuperview()
        }
        while visualEffect.subviews.count < item.icons.count {
            let iconView = DockIconView(frame: DockIconRowItem.iconSize.bounds)
            visualEffect.addSubview(iconView)
        }
        
        for (i, icon) in item.icons.enumerated() {
            let view = visualEffect.subviews[i] as! DockIconView
            view.set(item: icon, rowItem: item, animated: animated)
            view.frame = icon.frame
        }
        
        backgroundView.backgroundMode = theme.backgroundMode
        
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        

        needsLayout = true
    }
}
