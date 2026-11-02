import AppKit
import Metal
import QuartzCore

let scale: CGFloat = 2
let viewport = CGSize(width: 800, height: 1000)
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(viewport.width * scale), height: Int(viewport.height * scale), mipmapped: false)
descriptor.usage = [.renderTarget, .shaderRead]
descriptor.storageMode = .shared
let texture = device.makeTexture(descriptor: descriptor)!

func patternImage(side: Int) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(3)
    var seed: UInt64 = 7
    for _ in 0 ..< 120 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = CGFloat(seed % UInt64(side))
        let y = CGFloat((seed >> 20) % UInt64(side))
        let r = CGFloat(10 + (seed >> 40) % 30)
        context.strokeEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }
    return context.makeImage()!
}

final class Scene {
    let root = CALayer()
    let background = CALayer()
    let foreground = CALayer()

    init(variant: String) {
        self.root.frame = CGRect(origin: .zero, size: viewport)
        self.root.contentsScale = scale
        self.background.frame = self.root.bounds
        let gradient = CAGradientLayer()
        gradient.frame = self.root.bounds
        gradient.colors = [NSColor(red: 0.86, green: 0.93, blue: 0.75, alpha: 1).cgColor, NSColor(red: 0.62, green: 0.82, blue: 0.67, alpha: 1).cgColor, NSColor(red: 0.95, green: 0.87, blue: 0.62, alpha: 1).cgColor, NSColor(red: 0.75, green: 0.86, blue: 0.9, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        self.background.addSublayer(gradient)
        let pattern = patternImage(side: 720)
        let tileSize = CGSize(width: 360, height: 360)
        var x: CGFloat = 0
        while x < viewport.width {
            var y: CGFloat = 0
            while y < viewport.height {
                let tile = CALayer()
                tile.frame = CGRect(origin: CGPoint(x: x, y: y), size: tileSize)
                tile.contents = pattern
                tile.contentsScale = scale
                tile.opacity = 0.5
                if variant != "plain" {
                    tile.compositingFilter = "softLightBlendMode"
                }
                self.background.addSublayer(tile)
                y += tileSize.height
            }
            x += tileSize.width
        }
        if variant == "rasterized" {
            self.background.shouldRasterize = true
            self.background.rasterizationScale = scale
        }
        self.root.addSublayer(self.background)
        self.foreground.frame = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height * 3)
        for i in 0 ..< 40 {
            let bubble = CALayer()
            bubble.frame = CGRect(x: i % 2 == 0 ? 20 : 380, y: CGFloat(i) * 72, width: 400, height: 60)
            bubble.backgroundColor = (i % 2 == 0 ? NSColor.white : NSColor(red: 0.88, green: 0.98, blue: 0.8, alpha: 1)).cgColor
            bubble.cornerRadius = 14
            self.foreground.addSublayer(bubble)
        }
        self.root.addSublayer(self.foreground)
    }
}

func readPixels() -> [UInt8] {
    let bytesPerRow = texture.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return pixels
}

func run(_ variant: String, frames: Int) -> (ms: Double, pixels: [UInt8]) {
    let scene = Scene(variant: variant)
    let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
    renderer.layer = scene.root
    renderer.bounds = scene.root.bounds
    CATransaction.flush()
    var times: [Double] = []
    for frame in 0 ..< frames + 20 {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.foreground.position = CGPoint(x: viewport.width / 2, y: viewport.height * 1.5 - CGFloat(frame % 600) * 3)
        CATransaction.commit()
        CATransaction.flush()
        let start = CACurrentMediaTime()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let fence = queue.makeCommandBuffer()!
        fence.commit()
        fence.waitUntilCompleted()
        if frame >= 20 {
            times.append(CACurrentMediaTime() - start)
        }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scene.foreground.position = CGPoint(x: viewport.width / 2, y: viewport.height * 1.5)
    CATransaction.commit()
    CATransaction.flush()
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    let fence = queue.makeCommandBuffer()!
    fence.commit()
    fence.waitUntilCompleted()
    let pixels = readPixels()
    renderer.layer = nil
    times.sort()
    return (times[times.count / 2] * 1000, pixels)
}

_ = NSApplication.shared
let frames = 300
var results: [String: (ms: Double, pixels: [UInt8])] = [:]
for round in 0 ..< 3 {
    for variant in ["filter", "rasterized", "plain"] {
        let result = run(variant, frames: frames)
        if round == 2 {
            results[variant] = result
        }
    }
}
for variant in ["filter", "rasterized", "plain"] {
    print(String(format: "WallpaperBlend %@: median %.3f ms/frame (%dx%d, 2x)", variant, results[variant]!.ms, texture.width, texture.height))
}
let a = results["filter"]!.pixels
let b = results["rasterized"]!.pixels
var worst = 0
var differing = 0
for i in 0 ..< a.count {
    let d = abs(Int(a[i]) - Int(b[i]))
    worst = max(worst, d)
    if d > 1 {
        differing += 1
    }
}
let c = results["plain"]!.pixels
var filterEffect = 0
for i in 0 ..< a.count where abs(Int(a[i]) - Int(c[i])) > 1 {
    filterEffect += 1
}
print("WallpaperBlend filter vs rasterized: max |d| \(worst)/255, \(differing) of \(a.count) channels differ by more than 1; filter vs plain: \(filterEffect) channels differ (the filter is applied)")
