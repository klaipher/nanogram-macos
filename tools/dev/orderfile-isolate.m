#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSURL *IsolatedContainerURL(id self, SEL _cmd, NSString *group) {
    NSString *root = NSProcessInfo.processInfo.environment[@"NANOGRAM_CONTAINER_ROOT"];
    NSURL *url = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:group] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}

static NSArray *NoOtherInstances(id self, SEL _cmd, NSString *bundleIdentifier) {
    return @[];
}

__attribute__((constructor)) static void InstallIsolation(void) {
    if (getenv("NANOGRAM_CONTAINER_ROOT") == NULL) {
        abort();
    }
    method_setImplementation(class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:)), (IMP)IsolatedContainerURL);
    method_setImplementation(class_getClassMethod(NSRunningApplication.class, @selector(runningApplicationsWithBundleIdentifier:)), (IMP)NoOtherInstances);
}
