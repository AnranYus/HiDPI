#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A HiDPI virtual display. Every mode has a 2x backing store:
/// a mode that "looks like" W x H points is rendered at 2W x 2H pixels.
/// The display exists only while this object is alive (or until -destroy).
@interface HDVirtualDisplay : NSObject

/// "SLVirtualDisplay", "CGVirtualDisplay" or nil when the system has neither.
@property (class, readonly, nullable) NSString *backendName;

/// @param pointSizes  CGSize values (in points) offered by the display. The first one is preferred.
- (nullable instancetype)initWithName:(NSString *)name
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                         serialNumber:(uint32_t)serialNumber
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                           pointSizes:(NSArray<NSValue *> *)pointSizes
                          refreshRate:(double)refreshRate
                                error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (readonly) CGDirectDisplayID displayID;

/// Removes the display from WindowServer. Safe to call more than once.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
