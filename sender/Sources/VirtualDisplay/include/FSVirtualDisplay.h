#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual monitor macOS treats as a real extended display for as long as this object lives.
/// Backed by the private CGVirtualDisplay API (macOS 11+), resolved at runtime.
@interface FSVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// width/height are the logical mode in points; with hiDPI the backing store is 2x.
+ (nullable instancetype)displayWithName:(NSString *)name
                                   width:(unsigned int)width
                                  height:(unsigned int)height
                             refreshRate:(double)refreshRate
                                   hiDPI:(BOOL)hiDPI;

@end

NS_ASSUME_NONNULL_END
