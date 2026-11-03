#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <Accelerate/Accelerate.h>
#include <cmath>
#import "TGRTCVideoYUVConversion.h"

static int failures = 0;

static void expect(BOOL condition, NSString *name) {
    fprintf(stderr, "%s: %s\n", condition ? "ok" : "FAIL", name.UTF8String);
    if (!condition) {
        failures++;
    }
}

typedef struct { int r; int g; int b; } RGB;

static RGB reference(uint8_t y, uint8_t cb, uint8_t cr, const vImage_YpCbCrToARGBMatrix *matrix, BOOL fullRange) {
    vImage_YpCbCrPixelRange range = fullRange
        ? (vImage_YpCbCrPixelRange){ 0, 128, 255, 255, 255, 0, 255, 0 }
        : (vImage_YpCbCrPixelRange){ 16, 128, 235, 240, 255, 0, 255, 0 };
    vImage_YpCbCrToARGB info;
    vImageConvert_YpCbCrToARGB_GenerateConversion(matrix, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, 0);
    uint8_t yData[4] = { y, y, y, y };
    uint8_t uvData[2] = { cb, cr };
    uint8_t argb[16] = { 0 };
    vImage_Buffer srcY = { yData, 2, 2, 2 };
    vImage_Buffer srcUV = { uvData, 1, 1, 2 };
    vImage_Buffer dst = { argb, 2, 2, 8 };
    uint8_t permute[4] = { 0, 1, 2, 3 };
    vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcUV, &dst, &info, permute, 255, 0);
    return (RGB){ argb[1], argb[2], argb[3] };
}

@interface Harness : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@end

@implementation Harness {
    CVMetalTextureCacheRef _textureCache;
}

- (instancetype)initWithShaderPath:(NSString *)path {
    self = [super init];
    _device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    _library = [_device newLibraryWithSource:source options:nil error:&error];
    if (_library == nil) {
        fprintf(stderr, "shader compile failed: %s\n", error.description.UTF8String);
    }
    _queue = [_device newCommandQueue];
    CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textureCache);
    return self;
}

- (id<MTLRenderPipelineState>)pipeline:(NSString *)fragmentName {
    id<MTLFunction> fragment = [_library newFunctionWithName:fragmentName];
    if (fragment == nil) {
        return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [_library newFunctionWithName:@"vertexPassthrough"];
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    return [_device newRenderPipelineStateWithDescriptor:descriptor error:nil];
}

- (id<MTLTexture>)planeWithValue:(uint8_t)value size:(int)size {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:size height:size mipmapped:NO];
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    NSMutableData *bytes = [NSMutableData dataWithLength:size * size];
    memset(bytes.mutableBytes, value, size * size);
    [texture replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 withBytes:bytes.bytes bytesPerRow:size];
    return texture;
}

- (RGB)render:(id<MTLRenderPipelineState>)pipeline textures:(NSArray<id<MTLTexture>> *)textures conversion:(TGRTCYUVConversion)conversion {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [_device newTextureWithDescriptor:descriptor];
    float vertices[16] = { -1.0, -1.0, 0.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0 };
    MTLRenderPassDescriptor *pass = [[MTLRenderPassDescriptor alloc] init];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    for (NSUInteger index = 0; index < textures.count; index++) {
        [encoder setFragmentTexture:textures[index] atIndex:index];
    }
    [encoder setFragmentBytes:&conversion length:sizeof(conversion) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit synchronizeResource:target];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    uint8_t pixel[4] = { 0 };
    [target getBytes:pixel bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(4, 4, 1, 1) mipmapLevel:0];
    return (RGB){ pixel[2], pixel[1], pixel[0] };
}

- (CVPixelBufferRef)createBiPlanar:(OSType)format y:(uint8_t)y cb:(uint8_t)cb cr:(uint8_t)cr matrix:(CFStringRef)matrix {
    NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(NULL, 16, 16, format, (__bridge CFDictionaryRef)attributes, &buffer);
    if (matrix != NULL) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    memset(yPlane, y, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0));
    uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    size_t uvBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1);
    for (size_t index = 0; index + 1 < uvBytes; index += 2) {
        uvPlane[index] = cb;
        uvPlane[index + 1] = cr;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

- (NSArray<id<MTLTexture>> *)texturesForBiPlanar:(CVPixelBufferRef)buffer {
    CVMetalTextureRef y = NULL;
    CVMetalTextureRef uv = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, buffer, NULL, MTLPixelFormatR8Unorm, 16, 16, 0, &y);
    CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, buffer, NULL, MTLPixelFormatRG8Unorm, 8, 8, 1, &uv);
    NSArray *result = @[ CVMetalTextureGetTexture(y), CVMetalTextureGetTexture(uv) ];
    CFRelease(y);
    CFRelease(uv);
    return result;
}

@end

static BOOL close(RGB a, RGB b, int tolerance) {
    return abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance;
}

static const uint8_t samples[][3] = { { 180, 90, 200 }, { 81, 90, 240 }, { 145, 54, 34 }, { 41, 240, 110 }, { 235, 128, 128 }, { 16, 128, 128 } };

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s MetalFunctions.metal\n", argv[0]);
            return 2;
        }
        Harness *harness = [[Harness alloc] initWithShaderPath:[NSString stringWithUTF8String:argv[1]]];
        id<MTLRenderPipelineState> i420 = [harness pipeline:@"fragmentColorConversion"];
        id<MTLRenderPipelineState> nv12 = [harness pipeline:@"fragmentColorConversionNV12"];
        expect(i420 != nil, @"the I420 fragment function builds");
        expect(nv12 != nil, @"an NV12 fragment function exists, so native frames skip the CPU toI420 copy");

        struct I420Case { const char *name; BOOL tagged; TGRTCYCbCrMatrix matrix; BOOL fullRange; const vImage_YpCbCrToARGBMatrix *reference; };
        const I420Case i420Cases[] = {
            { "untagged I420 stays full-range BT.601", NO, TGRTCYCbCrMatrixBT601, YES, kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 },
            { "I420 tagged limited-range BT.601 (screen share, Q5) is expanded", YES, TGRTCYCbCrMatrixBT601, NO, kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 },
            { "I420 tagged full-range BT.709 uses the 709 matrix", YES, TGRTCYCbCrMatrixBT709, YES, kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 },
        };
        for (const I420Case &item : i420Cases) {
            BOOL matches = i420 != nil;
            for (const auto &sample : samples) {
                if (i420 == nil) {
                    break;
                }
                NSObject *frame = [[NSObject alloc] init];
                if (item.tagged) {
                    TGRTCVideoFrameSetYUVColorSpace(frame, item.matrix, item.fullRange);
                }
                RGB actual = [harness render:i420 textures:@[ [harness planeWithValue:sample[0] size:16], [harness planeWithValue:sample[1] size:8], [harness planeWithValue:sample[2] size:8] ] conversion:TGRTCYUVConversionForI420Frame(frame)];
                RGB expected = reference(sample[0], sample[1], sample[2], item.reference, item.fullRange);
                if (!close(actual, expected, 2)) {
                    fprintf(stderr, "  %s: %d,%d,%d → %d,%d,%d, expected %d,%d,%d\n", item.name, sample[0], sample[1], sample[2], actual.r, actual.g, actual.b, expected.r, expected.g, expected.b);
                    matches = NO;
                }
            }
            expect(matches, [NSString stringWithUTF8String:item.name]);
        }

        struct NV12Case { const char *name; OSType format; CFStringRef matrix; BOOL fullRange; const vImage_YpCbCrToARGBMatrix *reference; };
        const NV12Case nv12Cases[] = {
            { "420f tagged BT.709 (camera, VT-decoded video) uses the 709 matrix", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2, YES, kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 },
            { "420v tagged BT.601 (ScreenCaptureKit share, Q5) is expanded", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVImageBufferYCbCrMatrix_ITU_R_601_4, NO, kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 },
            { "420v tagged BT.709 is expanded with the 709 matrix", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2, NO, kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 },
            { "untagged 420f stays full-range BT.601", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, YES, kvImage_YpCbCrToARGBMatrix_ITU_R_601_4 },
        };
        for (const NV12Case &item : nv12Cases) {
            BOOL matches = nv12 != nil;
            for (const auto &sample : samples) {
                if (nv12 == nil) {
                    break;
                }
                CVPixelBufferRef buffer = [harness createBiPlanar:item.format y:sample[0] cb:sample[1] cr:sample[2] matrix:item.matrix];
                RGB actual = [harness render:nv12 textures:[harness texturesForBiPlanar:buffer] conversion:TGRTCYUVConversionForPixelBuffer(buffer)];
                CVPixelBufferRelease(buffer);
                RGB expected = reference(sample[0], sample[1], sample[2], item.reference, item.fullRange);
                if (!close(actual, expected, 2)) {
                    fprintf(stderr, "  %s: %d,%d,%d → %d,%d,%d, expected %d,%d,%d\n", item.name, sample[0], sample[1], sample[2], actual.r, actual.g, actual.b, expected.r, expected.g, expected.b);
                    matches = NO;
                }
            }
            expect(matches, [NSString stringWithUTF8String:item.name]);
        }

        if (i420 != nil) {
            NSObject *frame = [[NSObject alloc] init];
            TGRTCVideoFrameSetYUVColorSpace(frame, TGRTCYCbCrMatrixBT601, NO);
            TGRTCYUVConversion limited = TGRTCYUVConversionForI420Frame(frame);
            RGB black = [harness render:i420 textures:@[ [harness planeWithValue:16 size:16], [harness planeWithValue:128 size:8], [harness planeWithValue:128 size:8] ] conversion:limited];
            RGB white = [harness render:i420 textures:@[ [harness planeWithValue:235 size:16], [harness planeWithValue:128 size:8], [harness planeWithValue:128 size:8] ] conversion:limited];
            expect(black.r <= 2 && black.g <= 2 && black.b <= 2 && white.r >= 253 && white.g >= 253 && white.b >= 253, @"limited-range screen share: black 16 renders ≤ 2 and white 235 renders ≥ 253 (Q5)");
        }

        {
            CVPixelBufferRef bgra = NULL;
            CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &bgra);
            TGRTCYUVConversion actual = TGRTCYUVConversionForPixelBuffer(bgra);
            TGRTCYUVConversion expected = TGRTCYUVConversionMake(TGRTCYCbCrMatrixBT601, NO);
            CVPixelBufferRelease(bgra);
            expect(memcmp(&actual, &expected, sizeof(actual)) == 0, @"BGRA buffers, which webrtc's toI420 converts with libyuv ARGBToI420, render as limited-range BT.601");
        }

        TGRTCYUVConversion standard = TGRTCYUVConversionDefault();
        float y = 0.7f, cb = 0.35f - 0.5f, cr = 0.78f - 0.5f;
        float r = standard.column0[0] * (y - standard.offset[0]) + standard.column2[0] * (cr + 0.5f - standard.offset[2]);
        float g = standard.column0[1] * (y - standard.offset[0]) + standard.column1[1] * (cb + 0.5f - standard.offset[1]) + standard.column2[1] * (cr + 0.5f - standard.offset[2]);
        float b = standard.column0[2] * (y - standard.offset[0]) + standard.column1[2] * (cb + 0.5f - standard.offset[1]);
        expect(fabsf(r - (y + 1.403f * cr)) < 0.003f && fabsf(g - (y - 0.344f * cb - 0.714f * cr)) < 0.003f && fabsf(b - (y + 1.770f * cb)) < 0.003f, @"the default full-range 601 matches the previous shader constants within 0.003");
    }
    return failures == 0 ? 0 : 1;
}
