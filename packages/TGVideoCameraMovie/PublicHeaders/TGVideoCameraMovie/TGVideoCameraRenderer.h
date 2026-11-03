#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

CMVideoDimensions TGVideoCameraCaptureDimensions(CMVideoDimensions source);
void TGVideoCameraTextureVertices(AVCaptureVideoOrientation orientation, bool mirror, CGFloat aspectRatio, float vertices[8]);

#ifdef __cplusplus
}
#endif

@protocol TGVideoCameraRenderer <NSObject>

@property (nonatomic, readonly) __attribute__((NSObject)) CMFormatDescriptionRef outputFormatDescription;
@property (nonatomic, assign) AVCaptureVideoOrientation orientation;
@property (nonatomic, assign) bool mirror;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, readonly) bool hasPreviousPixelbuffer;
@property (nonatomic, assign) NSInteger decorationFrame;
@property (nonatomic, assign) NSInteger outputSide;

- (void)setDecorationWatermark:(CGImageRef)watermark planeFrames:(CGImageRef)planeFrames planeFrameCount:(NSInteger)planeFrameCount;
- (bool)prepareForInputWithFormatDescription:(CMFormatDescriptionRef)inputFormatDescription outputRetainedBufferCountHint:(size_t)outputRetainedBufferCountHint;
- (void)reset;

- (CVPixelBufferRef)copyRenderedPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)setPreviousPixelBuffer:(CVPixelBufferRef)previousPixelBuffer;

@end
