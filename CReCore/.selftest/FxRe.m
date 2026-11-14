#import <Foundation/Foundation.h>

@protocol FxProto <NSObject>
- (void)fxProtoMethod;
@end

@interface FxAlpha : NSObject <FxProto>
{
    int _fxCounter;
    id _fxPayload;
}
@property (nonatomic, copy) NSString *fxName;
@property (nonatomic, assign) NSInteger fxCount;
- (void)fxAlphaOne;
- (void)fxAlphaTwo:(NSString *)arg;
- (int)fxAlphaThree:(int)a with:(int)b;
+ (instancetype)fxAlphaMake;
@end

@implementation FxAlpha
@synthesize fxName = _fxName;
- (void)fxProtoMethod {}
- (void)fxAlphaOne {}
- (void)fxAlphaTwo:(NSString *)arg { (void)arg; }
- (int)fxAlphaThree:(int)a with:(int)b { return a + b; }
+ (instancetype)fxAlphaMake { return [[self alloc] init]; }
@end

@interface FxAlpha (Extra)
- (void)fxCategoryMethod;
@end
@implementation FxAlpha (Extra)
- (void)fxCategoryMethod {}
@end

@interface FxBeta : NSObject
- (void)fxBetaOne;
- (void)fxBetaTwo;
@end
@implementation FxBeta
- (void)fxBetaOne {}
- (void)fxBetaTwo {}
@end

@interface FxGamma : NSObject
- (void)fxGammaOne;
@end
@implementation FxGamma
- (void)fxGammaOne {}
@end

void fx_strings(void) {
    NSString *a = @"FxMarkerAlphaString";
    const char *b = "FxMarkerCString";
    NSLog(@"%@ %s", a, b);
}
