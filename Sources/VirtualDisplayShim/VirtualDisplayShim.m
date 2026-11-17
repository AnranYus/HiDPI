#import "VirtualDisplayShim.h"
#import <objc/message.h>
#include <dlfcn.h>

// Struct layouts taken from the runtime type encodings on macOS 27:
//   SLVirtualDisplayConfiguration sizeInMillimeters   {?=ff}
//   SLVirtualDisplayConfiguration maximumSizeInPixels {?=II}
//   SLVirtualDisplayConfiguration chromaticities      {?={?=ff}{?=ff}{?=ff}{?=ff}}
typedef struct { float width, height; } HDFloatSize;
typedef struct { uint32_t width, height; } HDPixelSize;
typedef struct { float x, y; } HDFloatPoint;
typedef struct { HDFloatPoint red, green, blue, white; } HDChromaticities;

static NSString *const HDErrorDomain = @"HiDPI.VirtualDisplay";

static NSError *HDMakeError(NSString *message, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:HDErrorDomain code:1 userInfo:info];
}

static void HDLoadSkyLight(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    });
}

static Class _Nullable HDClass(NSString *name) {
    HDLoadSkyLight();
    return NSClassFromString(name);
}

static BOOL HDHasSkyLight(void) {
    Class display = HDClass(@"SLVirtualDisplay");
    Class config = HDClass(@"SLVirtualDisplayConfiguration");
    Class mode = HDClass(@"SLVirtualDisplayMode");
    Class settings = HDClass(@"SLVirtualDisplaySettings");
    return display && config && mode && settings &&
        [config instancesRespondToSelector:NSSelectorFromString(@"initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:")] &&
        [mode instancesRespondToSelector:NSSelectorFromString(@"initWithSizeInPixels:sizeInPoints:refreshRate:error:")] &&
        [settings instancesRespondToSelector:NSSelectorFromString(@"initWithNativeMode:preferredMode:optionalModes:rotations:error:")] &&
        [display instancesRespondToSelector:NSSelectorFromString(@"initWithConfiguration:error:")];
}

static BOOL HDHasCoreGraphics(void) {
    return HDClass(@"CGVirtualDisplay") && HDClass(@"CGVirtualDisplayDescriptor") &&
        HDClass(@"CGVirtualDisplayMode") && HDClass(@"CGVirtualDisplaySettings");
}

@implementation HDVirtualDisplay {
    id _display;
    BOOL _skyLight;
}

+ (NSString *)backendName {
    if (HDHasSkyLight()) return @"SLVirtualDisplay";
    if (HDHasCoreGraphics()) return @"CGVirtualDisplay";
    return nil;
}

- (instancetype)initWithName:(NSString *)name
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
           sizeInMillimeters:(CGSize)sizeInMillimeters
                  pointSizes:(NSArray<NSValue *> *)pointSizes
                 refreshRate:(double)refreshRate
                       error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    if (pointSizes.count == 0) {
        if (error) *error = HDMakeError(@"No resolutions were given for the virtual display.", nil);
        return nil;
    }

    NSError *failure = nil;
    @try {
        if (HDHasSkyLight()) {
            _skyLight = YES;
            _display = [self createSkyLight:name vendor:vendorID product:productID serial:serialNumber
                                         mm:sizeInMillimeters points:pointSizes hz:refreshRate error:&failure];
        } else if (HDHasCoreGraphics()) {
            _display = [self createCoreGraphics:name vendor:vendorID product:productID serial:serialNumber
                                             mm:sizeInMillimeters points:pointSizes hz:refreshRate error:&failure];
        } else {
            failure = HDMakeError(@"This version of macOS has no virtual display API.", nil);
        }
    } @catch (NSException *exception) {
        failure = HDMakeError([NSString stringWithFormat:@"The virtual display API raised %@: %@",
                               exception.name, exception.reason], nil);
        _display = nil;
    }

    if (!_display || self.displayID == kCGNullDirectDisplay) {
        if (_display) [self destroy];
        if (error) *error = failure ?: HDMakeError(@"The virtual display was created without a display ID.", nil);
        return nil;
    }
    return self;
}

#pragma mark SkyLight (macOS 27+)

- (nullable id)createSkyLight:(NSString *)name vendor:(uint32_t)vendor product:(uint32_t)product serial:(uint32_t)serial
                           mm:(CGSize)mm points:(NSArray<NSValue *> *)points hz:(double)hz error:(NSError **)error {
    uint32_t maxW = 0, maxH = 0;
    for (NSValue *v in points) {
        CGSize s = v.sizeValue;
        maxW = MAX(maxW, (uint32_t)s.width * 2);
        maxH = MAX(maxH, (uint32_t)s.height * 2);
    }

    // sRGB / D65 primaries.
    HDChromaticities chroma = { {0.640f, 0.330f}, {0.300f, 0.600f}, {0.150f, 0.060f}, {0.3127f, 0.3290f} };
    HDFloatSize sizeMM = { (float)mm.width, (float)mm.height };
    HDPixelSize maxPixels = { maxW, maxH };

    NSError *err = nil;
    id config = [HDClass(@"SLVirtualDisplayConfiguration") alloc];
    config = ((id (*)(id, SEL, id, uint64_t, uint64_t, uint64_t, HDFloatSize, HDPixelSize, HDChromaticities, NSError **))objc_msgSend)(
        config, NSSelectorFromString(@"initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:"),
        name, vendor, product, serial, sizeMM, maxPixels, chroma, &err);
    if (!config) {
        if (error) *error = HDMakeError(@"Could not create the virtual display configuration.", err);
        return nil;
    }

    NSMutableArray *modes = [NSMutableArray array];
    SEL modeInit = NSSelectorFromString(@"initWithSizeInPixels:sizeInPoints:refreshRate:error:");
    for (NSValue *v in points) {
        CGSize s = v.sizeValue;
        HDPixelSize pts = { (uint32_t)s.width, (uint32_t)s.height };
        HDPixelSize px = { pts.width * 2, pts.height * 2 };
        err = nil;
        id mode = ((id (*)(id, SEL, HDPixelSize, HDPixelSize, float, NSError **))objc_msgSend)(
            [HDClass(@"SLVirtualDisplayMode") alloc], modeInit, px, pts, (float)hz, &err);
        if (!mode) {
            if (error) *error = HDMakeError([NSString stringWithFormat:@"Could not create the %ux%u mode.", pts.width, pts.height], err);
            return nil;
        }
        [modes addObject:mode];
    }

    // The native mode is the largest one; the preferred mode is the first one requested.
    id preferred = modes.firstObject;
    id native = preferred;
    uint64_t nativeArea = 0;
    for (NSUInteger i = 0; i < modes.count; i++) {
        CGSize s = points[i].sizeValue;
        uint64_t area = (uint64_t)s.width * (uint64_t)s.height;
        if (area > nativeArea) { nativeArea = area; native = modes[i]; }
    }
    NSMutableArray *optional = [modes mutableCopy];
    [optional removeObjectIdenticalTo:native];

    err = nil;
    id settings = ((id (*)(id, SEL, id, id, id, uint64_t, NSError **))objc_msgSend)(
        [HDClass(@"SLVirtualDisplaySettings") alloc],
        NSSelectorFromString(@"initWithNativeMode:preferredMode:optionalModes:rotations:error:"),
        native, preferred, optional, (uint64_t)0, &err);
    if (!settings) {
        if (error) *error = HDMakeError(@"Could not create the virtual display settings.", err);
        return nil;
    }

    err = nil;
    id display = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        [HDClass(@"SLVirtualDisplay") alloc], NSSelectorFromString(@"initWithConfiguration:error:"), config, &err);
    if (!display) {
        if (error) *error = HDMakeError(@"WindowServer refused to create the virtual display.", err);
        return nil;
    }

    err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
        display, NSSelectorFromString(@"applySettings:error:"), settings, &err);
    if (!ok) {
        ((void (*)(id, SEL))objc_msgSend)(display, NSSelectorFromString(@"destroy"));
        if (error) *error = HDMakeError(@"WindowServer rejected the virtual display modes.", err);
        return nil;
    }
    return display;
}

#pragma mark CoreGraphics (macOS 11 - 26)

- (nullable id)createCoreGraphics:(NSString *)name vendor:(uint32_t)vendor product:(uint32_t)product serial:(uint32_t)serial
                               mm:(CGSize)mm points:(NSArray<NSValue *> *)points hz:(double)hz error:(NSError **)error {
    uint32_t maxW = 0, maxH = 0;
    for (NSValue *v in points) {
        maxW = MAX(maxW, (uint32_t)v.sizeValue.width * 2);
        maxH = MAX(maxH, (uint32_t)v.sizeValue.height * 2);
    }

    id descriptor = [[HDClass(@"CGVirtualDisplayDescriptor") alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(descriptor, @selector(setName:), name);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(descriptor, NSSelectorFromString(@"setVendorID:"), vendor);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(descriptor, NSSelectorFromString(@"setProductID:"), product);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(descriptor, NSSelectorFromString(@"setSerialNum:"), serial);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(descriptor, NSSelectorFromString(@"setMaxPixelsWide:"), maxW);
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(descriptor, NSSelectorFromString(@"setMaxPixelsHigh:"), maxH);
    ((void (*)(id, SEL, CGSize))objc_msgSend)(descriptor, NSSelectorFromString(@"setSizeInMillimeters:"), mm);
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(descriptor, NSSelectorFromString(@"setRedPrimary:"), CGPointMake(0.640, 0.330));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(descriptor, NSSelectorFromString(@"setGreenPrimary:"), CGPointMake(0.300, 0.600));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(descriptor, NSSelectorFromString(@"setBluePrimary:"), CGPointMake(0.150, 0.060));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(descriptor, NSSelectorFromString(@"setWhitePoint:"), CGPointMake(0.3127, 0.3290));
    ((void (*)(id, SEL, id))objc_msgSend)(descriptor, NSSelectorFromString(@"setQueue:"), dispatch_get_main_queue());

    id display = ((id (*)(id, SEL, id))objc_msgSend)([HDClass(@"CGVirtualDisplay") alloc],
                                                    NSSelectorFromString(@"initWithDescriptor:"), descriptor);
    if (!display) {
        if (error) *error = HDMakeError(@"WindowServer refused to create the virtual display.", nil);
        return nil;
    }

    // Modes are given in points; hiDPI = 1 gives each of them a 2x backing store.
    NSMutableArray *modes = [NSMutableArray array];
    SEL modeInit = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    for (NSValue *v in points) {
        id mode = ((id (*)(id, SEL, uint32_t, uint32_t, double))objc_msgSend)(
            [HDClass(@"CGVirtualDisplayMode") alloc], modeInit,
            (uint32_t)v.sizeValue.width, (uint32_t)v.sizeValue.height, hz);
        if (mode) [modes addObject:mode];
    }

    id settings = [[HDClass(@"CGVirtualDisplaySettings") alloc] init];
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(settings, NSSelectorFromString(@"setHiDPI:"), 1);
    ((void (*)(id, SEL, id))objc_msgSend)(settings, NSSelectorFromString(@"setModes:"), modes);

    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"applySettings:"), settings);
    if (!ok) {
        if (error) *error = HDMakeError(@"WindowServer rejected the virtual display modes.", nil);
        return nil;
    }
    return display;
}

#pragma mark -

- (CGDirectDisplayID)displayID {
    if (!_display) return kCGNullDirectDisplay;
    return ((uint32_t (*)(id, SEL))objc_msgSend)(_display, NSSelectorFromString(@"displayID"));
}

- (void)destroy {
    id display = _display;
    _display = nil;
    if (!display) return;
    SEL destroy = NSSelectorFromString(@"destroy");
    if ([display respondsToSelector:destroy]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(display, destroy); } @catch (NSException *e) {}
    }
    // CGVirtualDisplay goes away when its last reference is released.
}

- (void)dealloc {
    [self destroy];
}

@end
