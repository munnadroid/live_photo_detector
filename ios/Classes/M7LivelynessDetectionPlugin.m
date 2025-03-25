#import "M7LivelynessDetectionPlugin.h"
#if __has_include(<live_photo_detector/live_photo_detector-Swift.h>)
#import <live_photo_detector/live_photo_detector-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "live_photo_detector-Swift.h"
#endif

@implementation M7LivelynessDetectionPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftM7LivelynessDetectionPlugin registerWithRegistrar:registrar];
}
@end
