import Cocoa
import AppKit


private func generateParticle(_ itemSize: NSSize, foregroundColor: NSColor) -> CGImage {
    return generateImage(itemSize, contextGenerator: { size, ctx in
        ctx.clear(CGRect(origin: .zero, size: size))
        ctx.round(size, itemSize.width / 2)
        ctx.setFillColor(foregroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    })!
}

private func generateList(_ count: Int, itemSize: NSSize, backgroundColor: NSColor, foregroundColor: NSColor, mask: Bool) -> CGImage {
    
    return generateImage(NSMakeSize(itemSize.width, (itemSize.height * CGFloat(count)) + (itemSize.width * CGFloat(count - 1))), contextGenerator: { size, ctx in
        ctx.clear(CGRect(origin: .zero, size: size))
        var pos: CGPoint = .zero
        let image = generateParticle(itemSize, foregroundColor: foregroundColor)
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        
        for _ in 0 ..< count {
            if (mask) {
                ctx.setBlendMode(.clear)
            }
            ctx.draw(image, in: CGRect(origin: pos, size: itemSize))
            pos.y += itemSize.height + itemSize.width
        }
    })!
}

public class VerticalParticleListControl: Control {
    
    private let unselected = ImageView()
    private let unselectedMask = ImageView()
    
    private let selected = ImageView()
    
    private var count: Int = 0
    private var selectedIndex: Int = -1
    private var itemSize: NSSize = .zero
    public var foregroundColor: NSColor? {
        didSet {
            if oldValue != foregroundColor {
                update(count: count, selectedIndex: selectedIndex, animated: false, force: true)
            }
        }
    }
    override init() {
        super.init(frame: .zero)
        setup()
    }
    required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    public override var isFlipped: Bool {
        return false
    }
    
    
    private func setup() {
        unselected.isEventLess = true
        selected.isEventLess = true
        unselectedMask.isEventLess = true
        //        unselected.animates = true
        //        unselectedMask.animates = true
        //        selected.animates = true
        addSubview(unselected)
        addSubview(selected)
        addSubview(unselectedMask)
    }
        
    
    public static let visibleSegments = 3

    public static func segmentHeight(count: Int, frameHeight: CGFloat, gap: CGFloat) -> CGFloat {
        let visible = CGFloat(min(max(1, count), visibleSegments))
        return max(1, floor((frameHeight - (visible - 1) * gap) / visible))
    }

    public static func positions(count: Int, selectedIndex: Int, frameHeight: CGFloat, gap: CGFloat) -> (list: CGFloat, selected: CGFloat) {
        let count = max(1, count)
        let segment = segmentHeight(count: count, frameHeight: frameHeight, gap: gap)
        let index = CGFloat(selectedIndex)
        let itemY = floor((segment * index) + (index * gap))
        let listHeight = (segment * CGFloat(count)) + (gap * CGFloat(count - 1))
        let maxDifference = -(listHeight - frameHeight)
        var list: CGFloat = 0
        if count > visibleSegments {
            let topDifference = itemY + segment - frameHeight
            list = max(min(0, -topDifference - ((frameHeight - segment) / 2)), maxDifference)
        }
        return (list: list, selected: itemY + list)
    }

    public func update(count: Int, selectedIndex: Int, animated: Bool, force: Bool = false) {
        self.selectedIndex = selectedIndex
        let count = max(1, count)
        let itemSize = NSMakeSize(frame.width, VerticalParticleListControl.segmentHeight(count: count, frameHeight: frame.height, gap: frame.width))

        let fgColor = self.foregroundColor ?? presentation.colors.accentIcon

        if self.count != count || self.itemSize != itemSize || force {
            self.unselected.image = generateList(max(1, count), itemSize: itemSize, backgroundColor: .clear, foregroundColor: fgColor.withAlphaComponent(0.2), mask: false)
            self.unselected.sizeToFit()

            self.unselectedMask.image = generateList(max(1, count), itemSize: itemSize, backgroundColor: .clear, foregroundColor: presentation.colors.grayIcon.withAlphaComponent(0.2), mask: true)
            self.unselectedMask.sizeToFit()

        }
        if self.itemSize != itemSize || force {
            selected.image = generateParticle(itemSize, foregroundColor: fgColor)
            selected.sizeToFit()
        }
        
        
        let positions = VerticalParticleListControl.positions(count: count, selectedIndex: selectedIndex, frameHeight: frame.height, gap: frame.width)
        let pos = NSMakePoint(0, positions.list)
        let selectedPoint = NSMakePoint(0, positions.selected)
        
        if animated {
            self.unselected.layer?.animatePosition(from: self.unselected.frame.origin - pos, to: .zero, duration: 0.4, timingFunction: .spring, additive: true)
            self.unselectedMask.layer?.animatePosition(from: self.unselectedMask.frame.origin - pos, to: .zero, duration: 0.4, timingFunction: .spring, additive: true)
            self.selected.layer?.animatePosition(from: self.selected.frame.origin - selectedPoint, to: .zero, duration: 0.4, timingFunction: .spring, additive: true)
        }
        self.unselected.setFrameOrigin(pos)
        self.unselectedMask.setFrameOrigin(pos)
        
        self.selected.setFrameOrigin(selectedPoint)
        
        self.count = count
        self.itemSize = itemSize
        self.selectedIndex = selectedIndex
    }
    
    public override func updateLocalizationAndTheme(theme: PresentationTheme) {
        super.updateLocalizationAndTheme(theme: theme)
        self.update(count: self.count, selectedIndex: selectedIndex, animated: false, force: true)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
