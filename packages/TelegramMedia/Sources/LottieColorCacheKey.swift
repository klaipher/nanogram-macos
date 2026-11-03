import AppKit

func lottieColorCacheKey(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    let component: (CGFloat) -> Int = { value in
        return max(0, min(255, Int((value * 255.0).rounded())))
    }
    return String(format: "%02X%02X%02X%02X", component(a), component(r), component(g), component(b))
}

public func inlineStickerCachePurpose(changesColorsLive: Bool) -> ASCachePurpose {
    if changesColorsLive {
        return .none
    }
    return .temporaryLZ4(.effect)
}
