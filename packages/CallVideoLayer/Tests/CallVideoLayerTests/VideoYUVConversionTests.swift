import Foundation
import Accelerate
import CoreVideo
import Metal
import XCTest
@testable import CallVideoLayer

private func makeUniformPixelBuffer(pixelFormat: OSType, y: UInt8, cb: UInt8, cr: UInt8, matrix: CFString?) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 64, pixelFormat, [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pixelBuffer)
    let buffer = try XCTUnwrap(pixelBuffer)
    if let matrix {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    memset(yPlane, Int32(y), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
    let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1)
    for index in stride(from: 0, to: uvBytes, by: 2) {
        uvPlane[index] = cb
        uvPlane[index + 1] = cr
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func vImageReference(y: UInt8, cb: UInt8, cr: UInt8, matrix: UnsafePointer<vImage_YpCbCrToARGBMatrix>, fullRange: Bool) -> (Int, Int, Int) {
    var pixelRange = fullRange ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0) : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    var info = vImage_YpCbCrToARGB()
    vImageConvert_YpCbCrToARGB_GenerateConversion(matrix, &pixelRange, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, 0)
    var yData = [UInt8](repeating: y, count: 4)
    var uvData: [UInt8] = [cb, cr]
    var argb = [UInt8](repeating: 0, count: 16)
    yData.withUnsafeMutableBytes { yBytes in
        uvData.withUnsafeMutableBytes { uvBytes in
            argb.withUnsafeMutableBytes { argbBytes in
                var srcY = vImage_Buffer(data: yBytes.baseAddress, height: 2, width: 2, rowBytes: 2)
                var srcUV = vImage_Buffer(data: uvBytes.baseAddress, height: 1, width: 1, rowBytes: 2)
                var dst = vImage_Buffer(data: argbBytes.baseAddress, height: 2, width: 2, rowBytes: 8)
                var permute: [UInt8] = [0, 1, 2, 3]
                _ = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcUV, &dst, &info, &permute, 255, 0)
            }
        }
    }
    return (Int(argb[1]), Int(argb[2]), Int(argb[3]))
}

private func shaderRender(_ pixelBuffer: CVPixelBuffer, conversion: VideoYUVConversion) throws -> (Int, Int, Int) {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/CallScreenShaders.metal").standardized
    let library = try device.makeLibrary(source: try String(contentsOf: sourceURL, encoding: .utf8), options: nil)
    let function = try XCTUnwrap(library.makeFunction(name: "videoBiPlanarDownscale"))
    let pipeline = try device.makeComputePipelineState(function: function)
    var textureCache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    var yTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, textureCache!, pixelBuffer, nil, .r8Unorm, 64, 64, 0, &yTexture)
    var uvTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, textureCache!, pixelBuffer, nil, .rg8Unorm, 32, 32, 1, &uvTexture)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    descriptor.storageMode = .shared
    let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(CVMetalTextureGetTexture(yTexture!), index: 0)
    encoder.setTexture(CVMetalTextureGetTexture(uvTexture!), index: 1)
    encoder.setTexture(output, index: 2)
    var parameters = conversion.shaderParameters
    encoder.setBytes(&parameters, length: MemoryLayout<VideoYUVConversion.ShaderParameters>.size, index: 0)
    encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    var pixel = [Float16](repeating: 0, count: 4)
    output.getBytes(&pixel, bytesPerRow: 8 * 8, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
    func level(_ value: Float16) -> Int {
        return Int((Float(value) * 255.0).rounded())
    }
    return (level(pixel[0]), level(pixel[1]), level(pixel[2]))
}

final class VideoYUVConversionTests: XCTestCase {
    private let samples: [(UInt8, UInt8, UInt8)] = [(180, 90, 200), (81, 90, 240), (145, 54, 34), (41, 240, 110), (235, 128, 128), (16, 128, 128)]

    private func check(pixelFormat: OSType, matrix: CFString?, reference: UnsafePointer<vImage_YpCbCrToARGBMatrix>, fullRange: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        for (y, cb, cr) in self.samples {
            let buffer = try makeUniformPixelBuffer(pixelFormat: pixelFormat, y: y, cb: cb, cr: cr, matrix: matrix)
            let conversion = VideoYUVConversion(pixelBuffer: buffer)
            let actual = try shaderRender(buffer, conversion: conversion)
            let expected = vImageReference(y: y, cb: cb, cr: cr, matrix: reference, fullRange: fullRange)
            XCTAssertEqual(actual.0, expected.0, accuracy: 2, "R for \(y),\(cb),\(cr)", file: file, line: line)
            XCTAssertEqual(actual.1, expected.1, accuracy: 2, "G for \(y),\(cb),\(cr)", file: file, line: line)
            XCTAssertEqual(actual.2, expected.2, accuracy: 2, "B for \(y),\(cb),\(cr)", file: file, line: line)
        }
    }

    func test709TaggedFullRangeFramesUseTheBT709Matrix() throws {
        try self.check(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, reference: kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, fullRange: true)
    }

    func test709TaggedVideoRangeFramesAreExpanded() throws {
        try self.check(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, reference: kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, fullRange: false)
    }

    func testUntaggedFullRangeFramesKeepFullRange601() throws {
        try self.check(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: nil, reference: kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, fullRange: true)
        XCTAssertEqual(VideoYUVConversion.fullRange601, VideoYUVConversion(matrix: .bt601, isFullRange: true))
    }

    func testFullRange601MatchesThePreviousShaderCoefficients() {
        let conversion = VideoYUVConversion.fullRange601
        for (y, u, v) in [(Float(0.7), Float(0.35), Float(0.78)), (0.3, 0.6, 0.4)] {
            let rgb = conversion.rgb(y: y, cb: u, cr: v)
            let cb = u - 0.5
            let cr = v - 0.5
            XCTAssertEqual(rgb.x, y + 1.403 * cr, accuracy: 0.003)
            XCTAssertEqual(rgb.y, y - 0.344 * cb - 0.714 * cr, accuracy: 0.003)
            XCTAssertEqual(rgb.z, y + 1.770 * cb, accuracy: 0.003)
        }
    }
}
