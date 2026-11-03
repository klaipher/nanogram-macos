#import "TGVideoCameraRenderer.h"

static const int32_t TGVideoCameraCaptureMaxLongSide = 1280;
static const int32_t TGVideoCameraCaptureMaxShortSide = 720;

CMVideoDimensions TGVideoCameraCaptureDimensions(CMVideoDimensions source)
{
    if (source.width <= 0 || source.height <= 0)
        return source;
    int32_t longSide = MAX(source.width, source.height);
    int32_t shortSide = MIN(source.width, source.height);
    double scale = MIN(1.0, MIN((double)TGVideoCameraCaptureMaxLongSide / longSide, (double)TGVideoCameraCaptureMaxShortSide / shortSide));
    if (scale >= 1.0)
        return source;
    CMVideoDimensions result;
    result.width = MAX(2, (int32_t)lround(source.width * scale / 2.0) * 2);
    result.height = MAX(2, (int32_t)lround(source.height * scale / 2.0) * 2);
    return result;
}

void TGVideoCameraTextureVertices(AVCaptureVideoOrientation orientation, bool mirror, CGFloat aspectRatio, float vertices[8])
{
    float centerOffset = (float)((1.0f - aspectRatio) / 2.0f);
    float lo = centerOffset;
    float hi = 1.0f - centerOffset;
    switch (orientation)
    {
        case AVCaptureVideoOrientationPortrait:
            if (!mirror)
            {
                float v[8] = { lo, 1.0f, lo, 0.0f, hi, 1.0f, hi, 0.0f };
                memcpy(vertices, v, sizeof(v));
            }
            else
            {
                float v[8] = { lo, 0.0f, hi, 0.0f, lo, 1.0f, hi, 1.0f };
                memcpy(vertices, v, sizeof(v));
            }
            break;
        case AVCaptureVideoOrientationLandscapeLeft:
            if (!mirror)
            {
                float v[8] = { hi, 1.0f, lo, 1.0f, hi, 0.0f, lo, 0.0f };
                memcpy(vertices, v, sizeof(v));
            }
            else
            {
                float v[8] = { lo, 0.0f, hi, 0.0f, lo, 1.0f, hi, 1.0f };
                memcpy(vertices, v, sizeof(v));
            }
            break;
        case AVCaptureVideoOrientationLandscapeRight:
            if (!mirror)
            {
                float v[8] = { lo, 0.0f, hi, 0.0f, lo, 1.0f, hi, 1.0f };
                memcpy(vertices, v, sizeof(v));
            }
            else
            {
                float v[8] = { hi, 1.0f, lo, 1.0f, hi, 0.0f, lo, 0.0f };
                memcpy(vertices, v, sizeof(v));
            }
            break;
        default:
            break;
    }
}
