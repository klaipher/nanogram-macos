#import <Foundation/Foundation.h>
#import "TGVideoCameraRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface TGVideoCameraMetalRenderer : NSObject <TGVideoCameraRenderer>

- (nullable instancetype)init;

+ (void)prewarm;
+ (void)prewarmWithCompletion:(nullable void (^)(BOOL ready))completion;
+ (NSInteger)pipelineCompileCount;

@end

NS_ASSUME_NONNULL_END
