#import "WebPScaledDecode.h"
#import "decode.h"

static void WebPScaledDecodeRelease(void *info, const void *data, size_t size) {
    free(info);
}

CGImageRef _Nullable WebPCreateImageFittingPixelSize(NSData * _Nonnull data, CGSize maxPixelSize) {
    if (data.length == 0) {
        return NULL;
    }
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) {
        return NULL;
    }
    if (WebPGetFeatures(data.bytes, data.length, &config.input) != VP8_STATUS_OK) {
        return NULL;
    }
    if (config.input.has_animation || config.input.width < 1 || config.input.height < 1) {
        return NULL;
    }
    int sourceWidth = config.input.width;
    int sourceHeight = config.input.height;
    double scale = 1.0;
    if (maxPixelSize.width >= 1.0 && maxPixelSize.height >= 1.0) {
        scale = MIN(1.0, MIN(maxPixelSize.width / sourceWidth, maxPixelSize.height / sourceHeight));
    }
    int width = MAX(1, (int)lround(sourceWidth * scale));
    int height = MAX(1, (int)lround(sourceHeight * scale));
    size_t bytesPerRow = (((size_t)width * 4) + 31) & ~(size_t)31;
    size_t length = bytesPerRow * (size_t)height;
    void *pixels = calloc(1, length);
    if (pixels == NULL) {
        return NULL;
    }
    if (width != sourceWidth || height != sourceHeight) {
        config.options.use_scaling = 1;
        config.options.scaled_width = width;
        config.options.scaled_height = height;
    }
    config.output.colorspace = MODE_bgrA;
    config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = pixels;
    config.output.u.RGBA.stride = (int)bytesPerRow;
    config.output.u.RGBA.size = length;
    VP8StatusCode status = WebPDecode(data.bytes, data.length, &config);
    WebPFreeDecBuffer(&config.output);
    if (status != VP8_STATUS_OK) {
        free(pixels);
        return NULL;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(pixels, pixels, length, WebPScaledDecodeRelease);
    if (provider == NULL) {
        free(pixels);
        return NULL;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace, kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}
