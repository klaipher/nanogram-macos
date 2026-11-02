import CoreGraphics
import Foundation

// Nanogram: CGWindowListCreateImage is obsoleted at a macOS 15 deployment target but still works at runtime,
// so it is looked up dynamically, the same way ModalMorphTransition.controlImage does.
public func windowListCreateImage(_ screenBounds: CGRect, _ listOption: CGWindowListOption, _ windowID: CGWindowID, _ imageOption: CGWindowImageOption) -> CGImage? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
        return nil
    }
    typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    return unsafeBitCast(symbol, to: Create.self)(screenBounds, listOption.rawValue, windowID, imageOption.rawValue)?.takeRetainedValue()
}
