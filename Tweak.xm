// LiquidGlassRewind for iOS 12.x
// Gives the Dock and Control Center an iOS 27 "Liquid Glass" look:
// real blur + saturation boost, flat tint, corner-lit specular rim, inner edge glow.
//
// Hooks (SpringBoard only):
//   SBFloatingDockPlatterView  - iPad dock platters (main + recents)
//   SBDockView                 - iPhone dock (and classic iPad dock)
//   MTMaterialView             - Control Center tile / slider / button backgrounds

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define LG_PREFS_ID @"com.lucid.liquidglass12"
#define LG_NOTIFY   CFSTR("com.lucid.liquidglass12/prefsChanged")

@protocol LGFilterFactory
+ (id)filterWithType:(NSString *)type;
@end

@interface SBDockView : UIView
@end
@interface SBFloatingDockPlatterView : UIView
@end
@interface MTMaterialView : UIView
@end

#pragma mark - Preferences

typedef struct {
    BOOL dock;        // glass dock
    BOOL cc;          // glass Control Center
    BOOL ccBackdrop;  // real blur behind every CC tile (heavier)
    BOOL compat;      // use UIVisualEffectView instead of CABackdropLayer
    CGFloat blur;
    CGFloat saturation;
    CGFloat tint;
    CGFloat rim;
    CGFloat shadow;
} LGPrefs;

static LGPrefs LG = { YES, YES, NO, NO, 22.0, 1.8, 0.14, 0.80, 0.22 };

static id LGCopyPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)LG_PREFS_ID);
    return v ? CFBridgingRelease(v) : nil;
}

static BOOL LGBoolPref(NSString *key, BOOL def) {
    id v = LGCopyPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}

static CGFloat LGFloatPref(NSString *key, CGFloat def, CGFloat lo, CGFloat hi) {
    id v = LGCopyPref(key);
    CGFloat f = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
    return MIN(MAX(f, lo), hi);
}

static void LGLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)LG_PREFS_ID);
    LG.dock       = LGBoolPref(@"dockEnabled", YES);
    LG.cc         = LGBoolPref(@"ccEnabled", YES);
    LG.ccBackdrop = LGBoolPref(@"ccBackdrop", NO);
    LG.compat     = LGBoolPref(@"compatBlur", NO);

    // One slider drives the whole look: 0 = Clear (see-through, light blur,
    // bright edges) ... 1 = Tinted (frosted, more opaque, adds contrast).
    CGFloat t = LGFloatPref(@"clearness", 0.4, 0.0, 1.0);
    LG.blur       = 6.0 + 20.0 * t;
    LG.saturation = 1.5 + 0.4 * t;
    LG.tint       = 0.02 + 0.34 * t;
    LG.rim        = 1.0 - 0.15 * t;
    LG.shadow     = 0.10 + 0.10 * t;
}

#pragma mark - Helpers

static void LGSet(id obj, NSString *key, id val) {
    @try { [obj setValue:val forKey:key]; } @catch (__unused NSException *e) {}
}

static UIView *LGViewForKey(UIView *v, NSString *key) {
    @try {
        id o = [v valueForKey:key];
        return [o isKindOfClass:[UIView class]] ? o : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL LGBackdropSupported(void) {
    return NSClassFromString(@"CABackdropLayer") != nil && NSClassFromString(@"CAFilter") != nil;
}

// Conic edge light: a faint, even rim all the way around plus two soft specular
// peaks at the top-left and bottom-right (light from the upper left), like the
// real material. Stops are fractions of a clockwise turn starting at 12 o'clock;
// in unit space the peaks land on the corners for any aspect ratio.
static void LGSetConic(CAGradientLayer *g, CGFloat base, CGFloat peak, CGFloat width) {
    const int n = 32;
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:n + 1];
    NSMutableArray *locs = [NSMutableArray arrayWithCapacity:n + 1];
    for (int i = 0; i <= n; i++) {
        CGFloat loc = (CGFloat)i / n;
        CGFloat d1 = fabs(loc - 0.875); d1 = MIN(d1, 1.0 - d1);
        CGFloat d2 = fabs(loc - 0.375); d2 = MIN(d2, 1.0 - d2);
        CGFloat k = MAX(exp(-pow(d1 / width, 2.0)), 0.8 * exp(-pow(d2 / width, 2.0)));
        CGFloat a = base + (peak - base) * MIN(1.0, k);
        [colors addObject:(__bridge id)[UIColor colorWithWhite:1.0 alpha:a].CGColor];
        [locs addObject:@(loc)];
    }
    g.colors = colors;
    g.locations = locs;
}

// Soft light that fades inward from the glass edge (gives the "thick glass" look).
static CAShapeLayer *LGMakeGlow(void) {
    CAShapeLayer *g = [CAShapeLayer layer];
    g.fillRule = kCAFillRuleEvenOdd;
    g.fillColor = [UIColor blackColor].CGColor;
    g.shadowColor = [UIColor whiteColor].CGColor;
    g.shadowRadius = 5.0;
    CAShapeLayer *m = [CAShapeLayer layer];
    m.fillColor = [UIColor blackColor].CGColor;
    g.mask = m;
    return g;
}

static void LGLayoutGlow(CAShapeLayer *g, CGRect b, CGFloat r) {
    g.frame = b;
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:CGRectInset(b, -60.0, -60.0)];
    [p appendPath:[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r]];
    g.path = p.CGPath;
    g.shadowPath = p.CGPath;
    CAShapeLayer *m = (CAShapeLayer *)g.mask;
    m.frame = g.bounds;
    m.path = [UIBezierPath bezierPathWithRoundedRect:g.bounds cornerRadius:r].CGPath;
}

#pragma mark - Backdrop view (real blur, private CABackdropLayer)

@interface LGBackdropView : UIView
@end

@implementation LGBackdropView
+ (Class)layerClass {
    Class c = NSClassFromString(@"CABackdropLayer");
    return c ?: [CALayer class];
}
@end

#pragma mark - Glass view

typedef NS_ENUM(NSInteger, LGKind) { LGKindDock = 0, LGKindCC = 1 };

static NSHashTable *LGRegistry;

@interface LGGlassView : UIView
@property (nonatomic, weak) UIView *host;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) LGKind kind;
- (instancetype)initWithKind:(LGKind)kind;
- (void)refresh;
@end

@implementation LGGlassView {
    UIView *_backdrop;
    int _backdropMode; // -1 unset, 0 none, 1 CABackdropLayer, 2 UIVisualEffectView
    CALayer *_shadowLayer;
    CALayer *_tintLayer;
    CAShapeLayer *_glowTL;
    CAShapeLayer *_glowBR;
    CAGradientLayer *_rimLayer;
    CAShapeLayer *_rimMask;
    CAGradientLayer *_innerRimLayer;
    CAShapeLayer *_innerRimMask;
}

- (instancetype)initWithKind:(LGKind)kind {
    if ((self = [super initWithFrame:CGRectZero])) {
        _kind = kind;
        _backdropMode = -1;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _shadowLayer = [CALayer layer];
        _shadowLayer.zPosition = -2;
        CAShapeLayer *shadowMask = [CAShapeLayer layer];
        shadowMask.fillRule = kCAFillRuleEvenOdd;
        shadowMask.fillColor = [UIColor blackColor].CGColor;
        _shadowLayer.mask = shadowMask;
        [self.layer addSublayer:_shadowLayer];

        _tintLayer = [CALayer layer];
        _tintLayer.masksToBounds = YES;

        _glowTL = LGMakeGlow();
        _glowTL.shadowOffset = CGSizeMake(2.5, 3.5);
        _glowBR = LGMakeGlow();
        _glowBR.shadowOffset = CGSizeMake(-2.0, -3.0);

        _rimLayer = [CAGradientLayer layer];
        _rimLayer.type = kCAGradientLayerConic;
        _rimLayer.startPoint = CGPointMake(0.5, 0.5);
        _rimLayer.endPoint = CGPointMake(0.5, 0.0);
        _rimMask = [CAShapeLayer layer];
        _rimMask.fillColor = nil;
        _rimMask.strokeColor = [UIColor blackColor].CGColor;
        _rimLayer.mask = _rimMask;

        _innerRimLayer = [CAGradientLayer layer];
        _innerRimLayer.type = kCAGradientLayerConic;
        _innerRimLayer.startPoint = CGPointMake(0.5, 0.5);
        _innerRimLayer.endPoint = CGPointMake(0.5, 0.0);
        _innerRimMask = [CAShapeLayer layer];
        _innerRimMask.fillColor = nil;
        _innerRimMask.strokeColor = [UIColor blackColor].CGColor;
        _innerRimLayer.mask = _innerRimMask;

        for (CALayer *l in @[_tintLayer, _glowBR, _glowTL, _innerRimLayer, _rimLayer]) {
            l.zPosition = 0;
            [self.layer addSublayer:l];
        }

        if (!LGRegistry) LGRegistry = [NSHashTable weakObjectsHashTable];
        [LGRegistry addObject:self];
    }
    return self;
}

- (void)setRadius:(CGFloat)radius {
    if (fabs(radius - _radius) > 0.01) {
        _radius = radius;
        [self setNeedsLayout];
    }
}

- (void)lg_setMode:(int)mode {
    [_backdrop removeFromSuperview];
    _backdrop = nil;
    _backdropMode = mode;
    if (mode == 1) {
        _backdrop = [[LGBackdropView alloc] initWithFrame:self.bounds];
    } else if (mode == 2) {
        _backdrop = [[UIVisualEffectView alloc]
                     initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
    }
    if (_backdrop) {
        _backdrop.userInteractionEnabled = NO;
        _backdrop.layer.zPosition = -1;
        [self insertSubview:_backdrop atIndex:0];
    }
}

- (void)refresh {
    BOOL wantsBackdrop = (_kind == LGKindDock) ? YES : LG.ccBackdrop;
    int mode = !wantsBackdrop ? 0 : ((LG.compat || !LGBackdropSupported()) ? 2 : 1);
    if (mode != _backdropMode) [self lg_setMode:mode];

    if (mode == 1) {
        Class<LGFilterFactory> factory = (Class<LGFilterFactory>)NSClassFromString(@"CAFilter");
        NSMutableArray *filters = [NSMutableArray array];

        id sat = [factory filterWithType:@"colorSaturate"];
        if (sat) {
            LGSet(sat, @"inputAmount", @(LG.saturation));
            [filters addObject:sat];
        }
        id blur = [factory filterWithType:@"gaussianBlur"];
        if (blur) {
            LGSet(blur, @"inputRadius", @(LG.blur));
            LGSet(blur, @"inputNormalizeEdges", @YES);
            [filters addObject:blur];
        }
        CALayer *l = _backdrop.layer;
        l.filters = filters;
        LGSet(l, @"windowServerAware", @YES);
        LGSet(l, @"enabled", @YES);
    }

    _tintLayer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:LG.tint].CGColor;
    _glowTL.shadowOpacity = 0.55 * LG.rim;
    _glowBR.shadowOpacity = 0.30 * LG.rim;
    LGSetConic(_rimLayer, 0.22 * LG.rim, LG.rim, 0.09);
    LGSetConic(_innerRimLayer, 0.06 * LG.rim, 0.40 * LG.rim, 0.09);

    _shadowLayer.hidden = (_kind != LGKindDock) || LG.shadow <= 0.01;
    _shadowLayer.shadowColor = [UIColor blackColor].CGColor;
    _shadowLayer.shadowOpacity = LG.shadow;
    _shadowLayer.shadowRadius = 16.0;
    _shadowLayer.shadowOffset = CGSizeMake(0.0, 6.0);

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (CGRectIsEmpty(b)) return;
    CGFloat r = MIN(_radius, MIN(b.size.width, b.size.height) / 2.0);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (_backdrop) {
        _backdrop.frame = b;
        CALayer *bl = _backdrop.layer;
        bl.cornerRadius = r;
        bl.masksToBounds = YES;
        LGSet(bl, @"continuousCorners", @YES);
    }

    _tintLayer.frame = b;
    _tintLayer.cornerRadius = r;

    LGLayoutGlow(_glowTL, b, r);
    LGLayoutGlow(_glowBR, b, r);

    CGFloat w = 1.5;
    _rimLayer.frame = b;
    _rimMask.frame = _rimLayer.bounds;
    _rimMask.lineWidth = w;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, w / 2.0, w / 2.0)
                                               cornerRadius:MAX(r - w / 2.0, 0)].CGPath;

    CGFloat iw = 1.0, inset = w + iw / 2.0;
    _innerRimLayer.frame = b;
    _innerRimMask.frame = _innerRimLayer.bounds;
    _innerRimMask.lineWidth = iw;
    _innerRimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, inset, inset)
                                                    cornerRadius:MAX(r - inset, 0)].CGPath;

    // Drop shadow that only shows outside the glass (not through it).
    _shadowLayer.frame = b;
    _shadowLayer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_shadowLayer.bounds
                                                         cornerRadius:r].CGPath;
    CGFloat pad = 80.0;
    CAShapeLayer *sm = (CAShapeLayer *)_shadowLayer.mask;
    sm.frame = CGRectInset(b, -pad, -pad);
    UIBezierPath *maskPath = [UIBezierPath bezierPathWithRect:sm.bounds];
    [maskPath appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(pad, pad, b.size.width, b.size.height)
                                                    cornerRadius:r]];
    sm.path = maskPath.CGPath;

    [CATransaction commit];
}

@end

#pragma mark - Attach / layout

static char kLGGlassKey;
static char kLGCheckedKey;

static LGGlassView *LGExistingGlass(UIView *host) {
    return objc_getAssociatedObject(host, &kLGGlassKey);
}

static void LGLayoutDock(UIView *host, UIView *bg, CGRect rect, CGFloat radius) {
    LGGlassView *g = LGExistingGlass(host);
    if (!g) {
        if (!LG.dock) return;
        g = [[LGGlassView alloc] initWithKind:LGKindDock];
        g.host = host;
        objc_setAssociatedObject(host, &kLGGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host insertSubview:g atIndex:0];
        [g refresh];
    }
    if (!LG.dock) {
        g.hidden = YES;
        bg.hidden = NO;
        return;
    }
    g.hidden = NO;
    bg.hidden = YES;
    g.frame = rect;
    g.radius = radius;
    if (g.superview != host || host.subviews.firstObject != g) {
        [host insertSubview:g atIndex:0];
    }
}

static BOOL LGInControlCenter(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        if (strncmp(class_getName([p class]), "CCUI", 4) == 0) return YES;
    }
    return NO;
}

static CGFloat LGCCRadius(UIView *v) {
    CGSize s = v.bounds.size;
    CGFloat maxR = MIN(s.width, s.height) / 2.0;
    CGFloat r = v.layer.cornerRadius;
    if (r <= 0.5) {
        UIView *p = v.superview;
        for (int i = 0; p && i < 3 && r <= 0.5; i++, p = p.superview) {
            if (fabs(p.bounds.size.width - s.width) < 2.0 &&
                fabs(p.bounds.size.height - s.height) < 2.0) {
                r = p.layer.cornerRadius;
            }
        }
    }
    if (r <= 0.5) {
        BOOL nearSquare = fabs(s.width - s.height) < 1.0 && s.width < 80.0;
        r = nearSquare ? maxR : MIN(maxR, 20.0);
    }
    return MIN(r, maxR);
}

static void LGLayoutCC(UIView *v) {
    LGGlassView *g = LGExistingGlass(v);
    if (!g) {
        if (!LG.cc || !v.window) return;
        if (objc_getAssociatedObject(v, &kLGCheckedKey)) return;
        CGSize s = v.bounds.size;
        if (s.width < 10.0 || s.height < 10.0) return; // wait for a real size

        BOOL eligible = LGInControlCenter(v);
        if (eligible) {
            CGRect sc = [UIScreen mainScreen].bounds;
            CGFloat m = MIN(sc.size.width, sc.size.height) * 0.9;
            if (s.width >= m && s.height >= m) eligible = NO; // full-screen backdrop
        }
        if (!eligible) {
            objc_setAssociatedObject(v, &kLGCheckedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        g = [[LGGlassView alloc] initWithKind:LGKindCC];
        g.host = v;
        objc_setAssociatedObject(v, &kLGGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:g];
        [g refresh];
    }
    g.hidden = !LG.cc;
    if (g.hidden) return;
    g.frame = v.bounds;
    g.radius = LGCCRadius(v);
    if (v.subviews.lastObject != g) [v bringSubviewToFront:g];
}

#pragma mark - Hooks

%hook SBFloatingDockPlatterView

- (void)layoutSubviews {
    %orig;
    UIView *bg = LGViewForKey(self, @"_backgroundView") ?: LGViewForKey(self, @"backgroundView");
    CGRect b = self.bounds;
    LGLayoutDock(self, bg, b, MIN(b.size.height / 2.0, 34.0));
}

%end

%hook SBDockView

- (void)layoutSubviews {
    %orig;
    UIView *bg = LGViewForKey(self, @"_backgroundView");
    if (!bg || CGRectIsEmpty(bg.frame)) return;
    CGRect r = CGRectInset(bg.frame, 10.0, 8.0);
    if (r.size.height <= 0 || r.size.width <= 0) return;
    LGLayoutDock(self, bg, r, MIN(r.size.height / 2.0, 34.0));
}

- (void)setBackgroundAlpha:(double)alpha {
    %orig;
    LGGlassView *g = LGExistingGlass(self);
    if (g) g.alpha = alpha;
}

%end

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    LGLayoutCC(self);
}

- (void)layoutSubviews {
    %orig;
    LGLayoutCC(self);
}

%end

#pragma mark - Live preference updates

static void LGPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLoadPrefs();
        for (LGGlassView *g in [LGRegistry allObjects]) {
            [g refresh];
            [g.host setNeedsLayout];
        }
    });
}

%ctor {
    @autoreleasepool {
        LGLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGPrefsChanged, LG_NOTIFY, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }
}
