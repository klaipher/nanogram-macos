import Foundation
import Accelerate
import TGUIKit

func scaleWebmFrame(_ source: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, to size: (w: Int, h: Int)) -> Data? {
    let destBytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: size.w)
    var destData = Data(count: size.h * destBytesPerRow)
    let result = destData.withUnsafeMutableBytes { (destBytes: UnsafeMutableRawBufferPointer) -> Bool in
        guard let destBaseAddress = destBytes.baseAddress else {
            return false
        }
        var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        var destBuffer = vImage_Buffer(data: destBaseAddress, height: vImagePixelCount(size.h), width: vImagePixelCount(size.w), rowBytes: destBytesPerRow)
        return vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
    }
    return result ? destData : nil
}
