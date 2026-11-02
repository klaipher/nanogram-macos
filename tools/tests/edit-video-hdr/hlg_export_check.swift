import Foundation
import AVFoundation
import CoreImage
import VideoToolbox

let width = 640, height = 360
let url = URL(fileURLWithPath: NSTemporaryDirectory() + "q11_hlg_\(UUID().uuidString).mov")
let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
let ctx = CIContext()
for i in 0..<20 {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    let colors: [CIColor] = [CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: hlg)!, CIColor(red: 0.75, green: 0.1, blue: 0.1, colorSpace: hlg)!, CIColor(red: 0.2, green: 0.6, blue: 0.2, colorSpace: hlg)!]
    var img = CIImage(color: colors[0]).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    img = CIImage(color: colors[1]).cropped(to: CGRect(x: 0, y: 0, width: width / 3, height: height)).composited(over: img)
    img = CIImage(color: colors[2]).cropped(to: CGRect(x: 2 * width / 3, y: 0, width: width / 3, height: height)).composited(over: img)
    ctx.render(img, to: pb!, bounds: img.extent, colorSpace: hlg)
    CVBufferSetAttachment(pb!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    while !input.isReadyForMoreMediaData { usleep(10000) }
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
print("writer", writer.status.rawValue, writer.error as Any)
let asset = AVURLAsset(url: url)

func patches(_ cg: CGImage) -> [(Int,Int,Int)] {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width*4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let d = c.data!.assumingMemoryBound(to: UInt8.self)
    return [cg.width/6, cg.width/2, 5*cg.width/6].map { x in let o = (cg.height/2*cg.width + x)*4; return (Int(d[o]), Int(d[o+1]), Int(d[o+2])) }
}
let gen = AVAssetImageGenerator(asset: asset)
let ref = try! gen.copyCGImage(at: CMTime(value: 5, timescale: 30), actualTime: nil)
print("reference SDR render", patches(ref))

func export(tag709: Bool, managed: Bool) -> [(Int,Int,Int)] {
    let context = managed ? CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]) : CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let comp = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { r in r.finish(with: r.sourceImage, context: context) })
    if tag709 { comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2; comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2 }
    let reader = try! AVAssetReader(asset: asset)
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: asset.tracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.videoComposition = comp
    reader.add(out); reader.startReading()
    var last: CVPixelBuffer?
    for _ in 0..<6 { if let s = out.copyNextSampleBuffer() { last = CMSampleBufferGetImageBuffer(s) } }
    let ci = CIImage(cvPixelBuffer: last!, options: [.colorSpace: CGColorSpace(name: tag709 ? CGColorSpace.itur_709 : CGColorSpace.sRGB)!])
    let cg = CIContext().createCGImage(ci, from: ci.extent)!
    return patches(cg)
}
print("today (untagged, NSNull ctx)", export(tag709: false, managed: false))
print("fix (709 tags, managed ctx)", export(tag709: true, managed: true))
print("709 tags only", export(tag709: true, managed: false))


func distance(_ a: [(Int,Int,Int)], _ b: [(Int,Int,Int)]) -> Int {
    return zip(a, b).map { max(abs($0.0 - $1.0), abs($0.1 - $1.1), abs($0.2 - $1.2)) }.max() ?? 0
}
let reference = patches(ref)
let fixed = export(tag709: true, managed: true)
let today = export(tag709: false, managed: false)
print("max channel error: fix \(distance(fixed, reference)), untagged \(distance(today, reference))")
if distance(fixed, reference) > 16 || distance(fixed, reference) >= distance(today, reference) {
    print("FAIL")
    exit(1)
}
print("PASS")
try? FileManager.default.removeItem(at: url)
