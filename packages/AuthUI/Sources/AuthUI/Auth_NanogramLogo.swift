import AppKit
import TGUIKit

func nanogramLogo(size: NSSize) -> CGImage? {
    guard let logo = NSImage(named: "Icon_NanogramComet") else {
        return nil
    }
    return generateImage(size, contextGenerator: { size, context in
        context.clear(size.bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        logo.draw(in: size.bounds)
        NSGraphicsContext.restoreGraphicsState()
    })
}
