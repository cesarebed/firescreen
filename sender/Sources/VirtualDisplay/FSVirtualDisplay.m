#import "FSVirtualDisplay.h"

// Private CoreGraphics interfaces, as used by Chromium and BetterDisplay.
@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation FSVirtualDisplay {
    id _display; // CGVirtualDisplay; the monitor disappears when this is released
}

+ (nullable instancetype)displayWithName:(NSString *)name
                                   width:(unsigned int)width
                                  height:(unsigned int)height
                             refreshRate:(double)refreshRate
                                   hiDPI:(BOOL)hiDPI {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descriptorClass || !displayClass || !modeClass || !settingsClass) return nil;

    unsigned int scale = hiDPI ? 2 : 1;
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = width * scale;
    descriptor.maxPixelsHigh = height * scale;
    // A 40" 16:9 panel; only affects the reported physical size and default scaling.
    descriptor.sizeInMillimeters = CGSizeMake(885, 498);
    descriptor.vendorID = 0xF15C;
    descriptor.productID = 0x0001;
    descriptor.serialNum = 0x0001;
    descriptor.terminationHandler = ^(id sender, CGVirtualDisplay *display) {};

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) return nil;

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate]];
    if (![display applySettings:settings]) return nil;

    FSVirtualDisplay *wrapper = [[self alloc] init];
    wrapper->_display = display;
    return wrapper;
}

- (CGDirectDisplayID)displayID {
    return [(CGVirtualDisplay *)_display displayID];
}

@end
