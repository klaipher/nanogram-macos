#import "TGVideoCameraMetalRenderer.h"
#import <Metal/Metal.h>
#import <CoreVideo/CVMetalTextureCache.h>
#import <simd/simd.h>
#import <math.h>

typedef struct {
    simd_float2 texcoords[4];
    float opacity;
    float aspectRatio;
    float noMirror;
    float decorated;
    float planeFrame;
    float planeFrameCount;
    float hasPrevious;
    float padding;
} TGVideoMessageUniforms;

static NSString *const TGVideoMessageMetalSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Uniforms { float2 texcoords[4]; float opacity; float aspectRatio; float noMirror; float decorated; float planeFrame; float planeFrameCount; float hasPrevious; float padding; };\n"
"struct VertexOut { float4 position [[position]]; float2 texcoord; float2 varPosition; };\n"
"vertex VertexOut videoMessageVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {\n"
"    const float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
"    float2 p = positions[vid];\n"
"    VertexOut out;\n"
"    out.position = float4(p.x, -p.y, 0.0, 1.0);\n"
"    out.texcoord = u.texcoords[vid];\n"
"    out.varPosition = p * 0.5 + 0.5;\n"
"    return out;\n"
"}\n"
"static float4 sourceOver(float4 overlay, float4 background) { return float4(overlay.rgb + background.rgb * (1.0 - overlay.a), 1.0); }\n"
"fragment float4 videoMessageFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> frame [[texture(0)]], texture2d<float> previous [[texture(1)]], texture2d<float> watermark [[texture(2)]], texture2d<float> plane [[texture(3)]]) {\n"
"    constexpr sampler trilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
"    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);\n"
"    float2 texcoord = float2(1.0 - in.texcoord.x * u.noMirror + clamp(u.noMirror, -1.0, 0.0), in.texcoord.y);\n"
"    float4 color = frame.sample(trilinear, texcoord);\n"
"    if (u.hasPrevious > 0.5) {\n"
"        color.rgb = mix(color.rgb, previous.sample(bilinear, in.varPosition).rgb, u.opacity);\n"
"    }\n"
"    float4 background = float4(frame.sample(trilinear, texcoord, bias(5.5)).rgb * 0.25, 1.0);\n"
"    if (u.decorated > 0.5) {\n"
"        float watermarkSize = 0.25;\n"
"        float2 watermarkOrigin = float2(1.0 - watermarkSize);\n"
"        if (in.varPosition.x >= watermarkOrigin.x && in.varPosition.y >= watermarkOrigin.y) {\n"
"            background = sourceOver(watermark.sample(bilinear, (in.varPosition - watermarkOrigin) / watermarkSize), background);\n"
"        }\n"
"        float planeSize = 0.17;\n"
"        float2 planeOrigin = float2(0.0, 1.0 - planeSize);\n"
"        if (in.varPosition.x < planeSize && in.varPosition.y >= planeOrigin.y) {\n"
"            float2 planeCoordinate = (in.varPosition - planeOrigin) / planeSize;\n"
"            background = sourceOver(plane.sample(bilinear, float2(planeCoordinate.x, (u.planeFrame + planeCoordinate.y) / u.planeFrameCount)), background);\n"
"        }\n"
"    }\n"
"    float2 c = float2((in.texcoord.x * 2.0 - 1.0) * u.aspectRatio, in.texcoord.y * 2.0 - 1.0) * 0.996;\n"
"    float2 c1 = c - 0.005;\n"
"    float2 c2 = c + 0.005;\n"
"    float2 c3 = float2(c1.x, c2.y);\n"
"    float2 c4 = float2(c2.x, c1.y);\n"
"    float s1 = step(1.0, dot(c1, c1));\n"
"    float s2 = step(1.0, dot(c2, c2));\n"
"    float s3 = step(1.0, dot(c3, c3));\n"
"    float s4 = step(1.0, dot(c4, c4));\n"
"    return mix(color, background, (s1 + s2 + s3 + s4) * 0.25);\n"
"}\n";

static NSInteger TGVideoMessagePipelineCompileCount = 0;

static id<MTLRenderPipelineState> TGVideoMessagePipeline(id<MTLDevice> device)
{
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pipelines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pipelines = [[NSMutableDictionary alloc] init];
    });
    @synchronized (pipelines) {
        NSNumber *key = @(device.registryID);
        id<MTLRenderPipelineState> pipeline = pipelines[key];
        if (pipeline != nil)
            return pipeline;
        NSError *error = nil;
        TGVideoMessagePipelineCompileCount += 1;
        id<MTLLibrary> library = [device newLibraryWithSource:TGVideoMessageMetalSource options:nil error:&error];
        if (library == nil)
            return nil;
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"videoMessageVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"videoMessageFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (pipeline != nil)
            pipelines[key] = pipeline;
        return pipeline;
    }
}

@interface TGVideoCameraMetalRenderer ()
{
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferPoolRef _bufferPool;
    CMFormatDescriptionRef _outputFormatDescription;
    CVPixelBufferRef _previousPixelBuffer;

    id<MTLTexture> _mipmappedFrame;
    id<MTLTexture> _watermarkTexture;
    id<MTLTexture> _planeTexture;
    id<MTLTexture> _emptyTexture;

    CGImageRef _watermarkImage;
    CGImageRef _planeFramesImage;
    NSInteger _planeFrameCount;

    CGFloat _aspectRatio;
    float _textureVertices[8];
}

@end

@implementation TGVideoCameraMetalRenderer

+ (void)prewarm
{
    [self prewarmWithCompletion:nil];
}

+ (void)prewarmWithCompletion:(void (^)(BOOL))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        BOOL ready = device != nil && TGVideoMessagePipeline(device) != nil;
        if (completion != nil)
            completion(ready);
    });
}

+ (NSInteger)pipelineCompileCount
{
    return TGVideoMessagePipelineCompileCount;
}

@synthesize orientation = _orientation;
@synthesize mirror = _mirror;
@synthesize opacity = _opacity;
@synthesize decorationFrame = _decorationFrame;
@synthesize outputSide = _outputSide;

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        _device = MTLCreateSystemDefaultDevice();
        if (_device == nil)
            return nil;
        _commandQueue = [_device newCommandQueue];
        _pipeline = TGVideoMessagePipeline(_device);
        if (_commandQueue == nil || _pipeline == nil)
            return nil;
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache) != kCVReturnSuccess)
            return nil;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:false];
        _emptyTexture = [_device newTextureWithDescriptor:descriptor];
        uint32_t clear = 0;
        [_emptyTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&clear bytesPerRow:4];
        _aspectRatio = 1.0;
    }
    return self;
}

- (void)dealloc
{
    [self deleteBuffers];
    if (_textureCache != NULL)
        CFRelease(_textureCache);
    if (_previousPixelBuffer != NULL)
        CFRelease(_previousPixelBuffer);
    CGImageRelease(_watermarkImage);
    CGImageRelease(_planeFramesImage);
}

- (void)setDecorationWatermark:(CGImageRef)watermark planeFrames:(CGImageRef)planeFrames planeFrameCount:(NSInteger)planeFrameCount
{
    CGImageRelease(_watermarkImage);
    CGImageRelease(_planeFramesImage);
    _watermarkImage = CGImageRetain(watermark);
    _planeFramesImage = CGImageRetain(planeFrames);
    _planeFrameCount = planeFrameCount;
}

- (id<MTLTexture>)textureWithImage:(CGImageRef)image
{
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0)
        return nil;
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data.mutableBytes, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL)
        return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:false];
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:data.bytes bytesPerRow:width * 4];
    return texture;
}

- (bool)prepareForInputWithFormatDescription:(CMFormatDescriptionRef)inputFormatDescription outputRetainedBufferCountHint:(size_t)outputRetainedBufferCountHint
{
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription);
    CGFloat minSide = MIN(dimensions.width, dimensions.height);
    CGFloat maxSide = MAX(dimensions.width, dimensions.height);
    if (minSide <= 0)
        return false;
    CGFloat outputSide = _outputSide > 0 ? MIN(minSide, (CGFloat)_outputSide) : minSide;
    if (outputSide >= 2)
        outputSide = floor(outputSide / 2.0) * 2.0;

    _aspectRatio = minSide / maxSide;
    [self updateTextureVertices];

    [self deleteBuffers];

    if (_watermarkImage != NULL && _planeFramesImage != NULL)
    {
        _watermarkTexture = [self textureWithImage:_watermarkImage];
        _planeTexture = [self textureWithImage:_planeFramesImage];
    }

    _bufferPool = [TGVideoCameraMetalRenderer createPixelBufferPoolWithWidth:(int32_t)outputSide height:(int32_t)outputSide pixelFormat:kCVPixelFormatType_32BGRA maxBufferCount:(int32_t)(outputRetainedBufferCountHint + 1)];
    if (_bufferPool == NULL)
        return false;

    CVPixelBufferRef testPixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &testPixelBuffer) != kCVReturnSuccess || testPixelBuffer == NULL)
    {
        [self deleteBuffers];
        return false;
    }
    CMFormatDescriptionRef outputFormatDescription = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, testPixelBuffer, &outputFormatDescription);
    CFRelease(testPixelBuffer);
    _outputFormatDescription = outputFormatDescription;
    return _outputFormatDescription != NULL;
}

- (CMFormatDescriptionRef)outputFormatDescription
{
    return _outputFormatDescription;
}

- (void)setOrientation:(AVCaptureVideoOrientation)orientation
{
    _orientation = orientation;
    [self updateTextureVertices];
}

- (void)setMirror:(bool)mirror
{
    _mirror = mirror;
    [self updateTextureVertices];
}

- (void)updateTextureVertices
{
    TGVideoCameraTextureVertices(_orientation, _mirror, _aspectRatio, _textureVertices);
}

- (void)reset
{
    [self deleteBuffers];
}

- (bool)hasPreviousPixelbuffer
{
    return _previousPixelBuffer != NULL;
}

- (void)setPreviousPixelBuffer:(CVPixelBufferRef)previousPixelBuffer
{
    if (_previousPixelBuffer != NULL)
    {
        CFRelease(_previousPixelBuffer);
        _previousPixelBuffer = NULL;
    }
    _previousPixelBuffer = previousPixelBuffer;
    if (_previousPixelBuffer != NULL)
        CFRetain(_previousPixelBuffer);
}

- (CVMetalTextureRef)createTextureForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA)
        return NULL;
    CVMetalTextureRef texture = NULL;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, pixelBuffer, NULL, MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture);
    if (result != kCVReturnSuccess)
        return NULL;
    return texture;
}

- (id<MTLTexture>)mipmappedFrameWithWidth:(NSUInteger)width height:(NSUInteger)height
{
    if (_mipmappedFrame != nil && _mipmappedFrame.width == width && _mipmappedFrame.height == height)
        return _mipmappedFrame;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:true];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    _mipmappedFrame = [_device newTextureWithDescriptor:descriptor];
    return _mipmappedFrame;
}

- (CVPixelBufferRef)copyRenderedPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (pixelBuffer == NULL || _bufferPool == NULL)
        return NULL;

    CVMetalTextureRef sourceTexture = [self createTextureForPixelBuffer:pixelBuffer];
    if (sourceTexture == NULL)
        return NULL;

    CVPixelBufferRef dstPixelBuffer = NULL;
    CVReturn err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &dstPixelBuffer);
    if (err != kCVReturnSuccess || dstPixelBuffer == NULL)
    {
        CVMetalTextureCacheFlush(_textureCache, 0);
        err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _bufferPool, &dstPixelBuffer);
    }
    if (err != kCVReturnSuccess || dstPixelBuffer == NULL)
    {
        CFRelease(sourceTexture);
        return NULL;
    }

    CVMetalTextureRef dstTexture = [self createTextureForPixelBuffer:dstPixelBuffer];
    CVMetalTextureRef previousTexture = _previousPixelBuffer != NULL ? [self createTextureForPixelBuffer:_previousPixelBuffer] : NULL;
    id<MTLTexture> source = CVMetalTextureGetTexture(sourceTexture);
    id<MTLTexture> destination = dstTexture != NULL ? CVMetalTextureGetTexture(dstTexture) : nil;
    id<MTLTexture> frame = source != nil ? [self mipmappedFrameWithWidth:source.width height:source.height] : nil;

    bool success = false;
    if (source != nil && destination != nil && frame != nil)
    {
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(source.width, source.height, 1) toTexture:frame destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit generateMipmapsForTexture:frame];
        [blit endEncoding];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = destination;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        bool decorated = _watermarkTexture != nil && _planeTexture != nil && _planeFrameCount > 0;
        id<MTLTexture> previous = previousTexture != NULL ? CVMetalTextureGetTexture(previousTexture) : nil;

        TGVideoMessageUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        for (int i = 0; i < 4; i++)
            uniforms.texcoords[i] = simd_make_float2(_textureVertices[i * 2], _textureVertices[i * 2 + 1]);
        uniforms.opacity = (float)_opacity;
        uniforms.aspectRatio = (float)(1.0 / _aspectRatio);
        uniforms.noMirror = _mirror ? 1.0f : -1.0f;
        uniforms.decorated = decorated ? 1.0f : 0.0f;
        uniforms.planeFrame = decorated ? (float)(_decorationFrame % _planeFrameCount) : 0.0f;
        uniforms.planeFrameCount = decorated ? (float)_planeFrameCount : 1.0f;
        uniforms.hasPrevious = previous != nil ? 1.0f : 0.0f;

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder setViewport:(MTLViewport){ 0.0, 0.0, (double)destination.width, (double)destination.height, 0.0, 1.0 }];
        [encoder setRenderPipelineState:_pipeline];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:frame atIndex:0];
        [encoder setFragmentTexture:previous ?: _emptyTexture atIndex:1];
        [encoder setFragmentTexture:decorated ? _watermarkTexture : _emptyTexture atIndex:2];
        [encoder setFragmentTexture:decorated ? _planeTexture : _emptyTexture atIndex:3];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];

        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        success = commandBuffer.status == MTLCommandBufferStatusCompleted;
    }

    CFRelease(sourceTexture);
    if (dstTexture != NULL)
        CFRelease(dstTexture);
    if (previousTexture != NULL)
        CFRelease(previousTexture);

    if (!success)
    {
        CFRelease(dstPixelBuffer);
        return NULL;
    }
    return dstPixelBuffer;
}

- (void)deleteBuffers
{
    if (_bufferPool != NULL)
    {
        CFRelease(_bufferPool);
        _bufferPool = NULL;
    }
    if (_outputFormatDescription != NULL)
    {
        CFRelease(_outputFormatDescription);
        _outputFormatDescription = NULL;
    }
    if (_textureCache != NULL)
        CVMetalTextureCacheFlush(_textureCache, 0);
    _mipmappedFrame = nil;
    _watermarkTexture = nil;
    _planeTexture = nil;
}

+ (CVPixelBufferPoolRef)createPixelBufferPoolWithWidth:(int32_t)width height:(int32_t)height pixelFormat:(FourCharCode)pixelFormat maxBufferCount:(int32_t)maxBufferCount
{
    CVPixelBufferPoolRef outputPool = NULL;
    NSDictionary *sourcePixelBufferOptions = @
    {
        (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFormat),
        (id)kCVPixelBufferWidthKey : @(width),
        (id)kCVPixelBufferHeightKey : @(height),
        (id)kCVPixelBufferMetalCompatibilityKey : @true,
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{ },
        (id)kCVBufferPropagatedAttachmentsKey : @
        {
            (id)kCVImageBufferYCbCrMatrixKey : (id)kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            (id)kCVImageBufferColorPrimariesKey : (id)kCVImageBufferColorPrimaries_ITU_R_709_2,
            (id)kCVImageBufferTransferFunctionKey : (id)kCVImageBufferTransferFunction_ITU_R_709_2
        }
    };
    NSDictionary *pixelBufferPoolOptions = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey : @(maxBufferCount) };
    CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)pixelBufferPoolOptions, (__bridge CFDictionaryRef)sourcePixelBufferOptions, &outputPool);
    return outputPool;
}

@end
