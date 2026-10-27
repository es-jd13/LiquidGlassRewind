// LiquidGlassRewind for iOS 12.x
// Gives the Dock, Control Center, folders and Today widgets an iOS 26/27 "Liquid Glass"
// look: real blur + saturation, gray veil, sharp lens-like edge band, hairline rim.
// Also restyles the status bar battery / Wi-Fi / signal and the CC slider glyphs.
//
// Hooks in SpringBoard:
//   SBFloatingDockPlatterView  - iPad dock platters (main + recents)
//   SBDockView                 - iPhone dock (and classic iPad dock)
//   MTMaterialView             - CC tiles and Today-widget platter backgrounds
//   SBFolderIconBackgroundView / SBFolderBackgroundView - folders
//   CCUIContinuousSliderView / CCUIModuleSliderView     - brightness / volume glyphs
// Hooks in every UIKit app (status bar is drawn per app):
//   UIStatusBarBatteryItemView / DataNetworkItemView / SignalStrengthItemView

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define LG_PREFS_ID @"com.es.jd.liquidglassrewind"
#define LG_NOTIFY   CFSTR("com.es.jd.liquidglassrewind/prefsChanged")

@protocol LGFilterFactory
+ (id)filterWithType:(NSString *)type;
@end

@interface SBDockView : UIView
@end
@interface SBFloatingDockPlatterView : UIView
@end
@interface MTMaterialView : UIView
@end
@interface _UIBackdropView : UIView
@end
@interface SBFolderIconBackgroundView : UIView
@end
@interface SBFolderBackgroundView : UIView
@end
@interface SBFolderIconImageView : UIView
@end
@interface WGWidgetPlatterView : UIView
@end
@interface CCUIContinuousSliderView : UIView
@end
@interface CCUIModuleSliderView : UIView
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
    CGFloat ccDim;     // darkness of the full-screen Control Center background
    BOOL sliders;      // colored sun / speaker glyphs on the CC sliders
    BOOL folders;      // glass folders
    BOOL widgets;      // glass Today-view widgets
    BOOL statusBar;    // iOS 26 style battery / Wi-Fi / signal icons
    BOOL sliderCurved; // reshape the CC slider track/fill into a full capsule (off = system shape)
} LGPrefs;

static LGPrefs LG = { YES, YES, NO, NO, 6.6, 1.5, 0.22, 0.96, 0.11, 0.45, YES, YES, YES, YES, NO };

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
    LG.ccDim      = LGFloatPref(@"ccDim", 0.45, 0.0, 0.85);
    LG.sliders    = LGBoolPref(@"sliderGlyphs", YES);
    LG.folders    = LGBoolPref(@"folderEnabled", YES);
    LG.widgets    = LGBoolPref(@"widgetEnabled", YES);
    LG.statusBar  = LGBoolPref(@"statusBarEnabled", YES);
    LG.sliderCurved = LGBoolPref(@"sliderCurved", NO);

    // One slider drives the whole look: 0 = Clear (see-through, light blur)
    // ... 1 = Tinted (more blur, more opaque, adds contrast).
    // Tuned against photos of the real iOS 26 dock and Control Center: the real
    // material is subtle, nearly clear, with a hairline edge, not a thick bright rim.
    CGFloat t = LGFloatPref(@"clearness", 0.4, 0.0, 1.0);
    LG.blur       = 3.0 + 9.0 * t;
    LG.saturation = 1.4 + 0.3 * t;
    LG.tint       = 0.10 + 0.30 * t;   // alpha of a mid-gray veil (low contrast, like the real glass)
    LG.rim        = 1.0 - 0.1 * t;
    LG.shadow     = 0.08 + 0.08 * t;
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
    g.shadowRadius = 4.0;
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

typedef NS_ENUM(NSInteger, LGKind) { LGKindDock = 0, LGKindCC = 1, LGKindSurface = 2 };

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
    UIView *_edgeBackdrop; // sharp, un-blurred band along the edge (lens-like edge)
    int _backdropMode; // -1 unset, 0 none, 1 CABackdropLayer, 2 UIVisualEffectView
    CALayer *_shadowLayer;
    CALayer *_decor;      // tint + rim + glows, rasterized once (cheap to animate)
    CGRect _lastBounds;
    CGFloat _lastRadius;
    BOOL _dirty;
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
        _glowTL.shadowOffset = CGSizeMake(1.5, 3.0);
        _glowBR = LGMakeGlow();
        _glowBR.shadowOffset = CGSizeMake(-1.0, -2.0);

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

        // Everything decorative lives in one container that Core Animation renders to a
        // bitmap once. Without this, every tile re-ran masks, shadows and conic
        // gradients each frame, which is what made Control Center laggy.
        _decor = [CALayer layer];
        _decor.zPosition = 0;
        _decor.shouldRasterize = YES;
        _decor.rasterizationScale = [UIScreen mainScreen].scale;
        for (CALayer *l in @[_tintLayer, _glowBR, _glowTL, _innerRimLayer, _rimLayer]) {
            [_decor addSublayer:l];
        }
        [self.layer addSublayer:_decor];
        _dirty = YES;

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
    [_edgeBackdrop removeFromSuperview];
    _backdrop = nil;
    _edgeBackdrop = nil;
    _backdropMode = mode;
    if (mode == 1) {
        _backdrop = [[LGBackdropView alloc] initWithFrame:self.bounds];
        if (_kind == LGKindDock) { // the sharp lens-edge band is dock-only (it doubles the blur cost)
            _edgeBackdrop = [[LGBackdropView alloc] initWithFrame:self.bounds];
            CAShapeLayer *mainMask = [CAShapeLayer layer];
            mainMask.fillColor = [UIColor blackColor].CGColor;
            _backdrop.layer.mask = mainMask;
            CAShapeLayer *edgeMask = [CAShapeLayer layer];
            edgeMask.fillColor = nil;
            edgeMask.strokeColor = [UIColor blackColor].CGColor;
            _edgeBackdrop.layer.mask = edgeMask;
        }
    } else if (mode == 2) {
        _backdrop = [[UIVisualEffectView alloc]
                     initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
    }
    if (_backdrop) {
        _backdrop.userInteractionEnabled = NO;
        _backdrop.layer.zPosition = -1;
        [self insertSubview:_backdrop atIndex:0];
    }
    if (_edgeBackdrop) {
        _edgeBackdrop.userInteractionEnabled = NO;
        _edgeBackdrop.layer.zPosition = -0.5;
        [self insertSubview:_edgeBackdrop aboveSubview:_backdrop];
    }
}

- (void)refresh {
    BOOL wantsBackdrop = (_kind == LGKindCC) ? LG.ccBackdrop : YES;
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

        // Edge band: no blur, a bit more color, so the rim reads like a thick lens edge.
        NSMutableArray *edgeFilters = [NSMutableArray array];
        id edgeSat = [factory filterWithType:@"colorSaturate"];
        if (edgeSat) {
            LGSet(edgeSat, @"inputAmount", @(LG.saturation + 0.25));
            [edgeFilters addObject:edgeSat];
        }
        CALayer *el = _edgeBackdrop.layer;
        el.filters = edgeFilters;
        LGSet(el, @"windowServerAware", @YES);
        LGSet(el, @"enabled", @YES);
    }

    CGFloat veil = (_kind == LGKindCC) ? LG.tint * 0.5 : LG.tint; // CC tiles already sit on a system blur
    _tintLayer.backgroundColor = [UIColor colorWithWhite:0.47 alpha:veil].CGColor;
    _glowTL.shadowOpacity = 0.12 * LG.rim;
    _glowBR.shadowOpacity = 0.06 * LG.rim;
    LGSetConic(_rimLayer, 0.16 * LG.rim, 0.80 * LG.rim, 0.09);
    LGSetConic(_innerRimLayer, 0.03 * LG.rim, 0.20 * LG.rim, 0.09);

    _shadowLayer.hidden = (_kind != LGKindDock) || LG.shadow <= 0.01;
    _shadowLayer.shadowColor = [UIColor blackColor].CGColor;
    _shadowLayer.shadowOpacity = LG.shadow;
    _shadowLayer.shadowRadius = 14.0;
    _shadowLayer.shadowOffset = CGSizeMake(0.0, 5.0);

    _dirty = YES;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (CGRectIsEmpty(b)) return;
    CGFloat r = MIN(_radius, MIN(b.size.width, b.size.height) / 2.0);
    if (!_dirty && CGRectEqualToRect(b, _lastBounds) && fabs(r - _lastRadius) < 0.01) return; // nothing changed: skip all path work
    _dirty = NO;
    _lastBounds = b;
    _lastRadius = r;
    _decor.frame = b;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (_backdrop) {
        _backdrop.frame = b;
        CALayer *bl = _backdrop.layer;
        if (_edgeBackdrop) {
            const CGFloat e = 4.0; // width of the sharp edge band
            CAShapeLayer *mm = (CAShapeLayer *)bl.mask;
            mm.frame = bl.bounds;
            mm.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, e - 0.5, e - 0.5)
                                                 cornerRadius:MAX(r - (e - 0.5), 0)].CGPath;
            _edgeBackdrop.frame = b;
            CAShapeLayer *em = (CAShapeLayer *)_edgeBackdrop.layer.mask;
            em.frame = _edgeBackdrop.layer.bounds;
            em.lineWidth = e;
            em.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, e / 2.0, e / 2.0)
                                                 cornerRadius:MAX(r - e / 2.0, 0)].CGPath;
        } else {
            bl.cornerRadius = r;
            bl.masksToBounds = YES;
            LGSet(bl, @"continuousCorners", @YES);
        }
    }

    _tintLayer.frame = b;
    _tintLayer.cornerRadius = r;

    LGLayoutGlow(_glowTL, b, r);
    LGLayoutGlow(_glowBR, b, r);

    CGFloat w = 0.7;
    _rimLayer.frame = b;
    _rimMask.frame = _rimLayer.bounds;
    _rimMask.lineWidth = w;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, w / 2.0, w / 2.0)
                                               cornerRadius:MAX(r - w / 2.0, 0)].CGPath;

    CGFloat iw = 0.6, inset = w + iw / 2.0;
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
static char kLGScopeKey;

static LGGlassView *LGExistingGlass(UIView *host) {
    return objc_getAssociatedObject(host, &kLGGlassKey);
}

static void LGLayoutDock(UIView *host, UIView *bg, CGRect rect, CGFloat radius, BOOL forceHostRadius) {
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
    if (forceHostRadius) {
        // The system rounds the platter itself (a full capsule in portrait). Use our
        // radius in every orientation so the dock matches the landscape look.
        host.layer.cornerRadius = radius;
        LGSet(host.layer, @"continuousCorners", @YES);
    }
    if (g.superview != host || host.subviews.firstObject != g) {
        [host insertSubview:g atIndex:0];
    }
}

typedef NS_ENUM(NSInteger, LGScope) { LGScopeNone = 0, LGScopeCC = 1, LGScopeWidget = 2, LGScopeFolder = 3 };

static BOOL LGInControlCenter(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        if (strncmp(class_getName([p class]), "CCUI", 4) == 0) return YES;
    }
    return NO;
}

static BOOL LGIsFullScreen(CGSize s) {
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat m = MIN(sc.size.width, sc.size.height) * 0.9;
    return s.width >= m && s.height >= m;
}

static BOOL LGHasSliderAncestor(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d < 5; p = p.superview, d++) {
        if (strstr(class_getName([p class]), "Slider")) return YES;
    }
    return NO;
}

// Which glass surface (if any) a material / effect view belongs to.
//   Control Center : inside a CCUI* view (child glass on top of the tile)
//   Today widgets  : the background of a WGWidgetPlatterView (not its header strip)
//   Folders        : inside SBFolderIcon* / SBFolderBackground* views
// Widgets and folders replace the system material with our own clear blur.
static LGScope LGScopeForView(UIView *v, BOOL allowCC) {
    int depth = 0;
    for (UIView *p = v; p; p = p.superview, depth++) {
        const char *n = class_getName([p class]);
        if (allowCC && strncmp(n, "CCUI", 4) == 0) return LGScopeCC;
        if (strncmp(n, "SBFolderIcon", 12) == 0 || strncmp(n, "SBFolderBackground", 18) == 0) return LGScopeFolder;
        if (strncmp(n, "WGWidgetPlatterView", 19) == 0) {
            if (p == v) return LGScopeNone;
            CGSize ps = p.bounds.size, vs = v.bounds.size;
            BOOL isBackground = depth <= 2 && vs.width >= ps.width * 0.95 && vs.height >= ps.height * 0.5;
            return isBackground ? LGScopeWidget : LGScopeNone;
        }
    }
    return LGScopeNone;
}

// iOS 26 shapes: circles for small buttons, capsules for sliders and wide pills,
// big soft-cornered squares for the modules.
static CGFloat LGCCShapeRadius(CGSize s) {
    CGFloat mn = MIN(s.width, s.height), mx = MAX(s.width, s.height);
    if (fabs(s.width - s.height) < 4.0 && mx <= 120.0) return mn / 2.0;   // round buttons
    if (mn <= 120.0 && mx >= 1.6 * mn) return mn / 2.0;                    // sliders, pills
    return MIN(30.0, mn / 2.0);                                            // modules
}

static CGFloat LGSurfaceRadius(LGScope scope, CGSize s) {
    CGFloat mn = MIN(s.width, s.height);
    if (scope == LGScopeWidget) return MIN(26.0, mn / 2.0);
    if (scope == LGScopeFolder) return mn <= 120.0 ? mn * 0.2237 : MIN(38.0, mn / 2.0);
    return LGCCShapeRadius(s);
}

// Round the tile itself. Parents are only touched if they already clip, so we never
// add extra offscreen masks to animating Control Center containers.
static void LGApplyRadius(UIView *v, CGFloat r, int maxDepth) {
    CGSize s = v.bounds.size;
    int depth = 0;
    for (UIView *p = v; p && depth < maxDepth; p = p.superview, depth++) {
        if (fabs(p.bounds.size.width - s.width) > 2.0 || fabs(p.bounds.size.height - s.height) > 2.0) break;
        if (p != v && !p.layer.masksToBounds) continue;
        if (fabs(p.layer.cornerRadius - r) > 0.01) {
            p.layer.cornerRadius = r;
            LGSet(p.layer, @"continuousCorners", @YES);
        }
        if (p == v && !p.layer.masksToBounds) p.layer.masksToBounds = YES;
    }
}

static char kLGDimKey;
static char kLGDimCheckedKey;
static NSHashTable *LGDimRegistry;

static UIView *LGDimContentHost(UIView *v) {
    if ([v isKindOfClass:[UIVisualEffectView class]]) return ((UIVisualEffectView *)v).contentView;
    return v;
}

static void LGUpdateDim(UIView *dim) {
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:LG.ccDim];
    dim.hidden = !(LG.cc && LG.ccDim > 0.01);
}

// Darken the full-screen (white-ish) blur behind Control Center, like iOS 26.
static void LGInstallDimIfNeeded(UIView *v) {
    UIView *dim = objc_getAssociatedObject(v, &kLGDimKey);
    if (!dim) {
        if (!LG.cc || LG.ccDim <= 0.01 || !v.window) return;
        if (objc_getAssociatedObject(v, &kLGDimCheckedKey)) return;
        CGSize s = v.bounds.size;
        if (s.width < 10.0 || s.height < 10.0) return;
        if (!LGIsFullScreen(s) || !LGInControlCenter(v)) {
            objc_setAssociatedObject(v, &kLGDimCheckedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        dim = [[UIView alloc] initWithFrame:CGRectZero];
        dim.userInteractionEnabled = NO;
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(v, &kLGDimKey, dim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!LGDimRegistry) LGDimRegistry = [NSHashTable weakObjectsHashTable];
        [LGDimRegistry addObject:dim];
        [LGDimContentHost(v) addSubview:dim];
    }
    LGUpdateDim(dim);
    UIView *host = LGDimContentHost(v);
    dim.frame = host.bounds;
    if (host.subviews.lastObject != dim) [host bringSubviewToFront:dim];
}

static BOOL LGSurfaceEnabled(LGScope s) {
    switch (s) {
        case LGScopeCC:     return LG.cc;
        case LGScopeWidget: return LG.widgets;
        case LGScopeFolder: return LG.folders;
        default:            return NO;
    }
}

// Widgets and folders: hide the system's frosted material and put our own clear
// blur (same recipe as the dock) right above it in the parent.
static void LGLayoutSibling(UIView *v, LGScope scope) {
    UIView *sv = v.superview;
    if (!sv) return;
    BOOL on = LGSurfaceEnabled(scope);
    LGGlassView *g = LGExistingGlass(v);
    if (!g) {
        if (!on) return;
        g = [[LGGlassView alloc] initWithKind:LGKindSurface];
        g.host = v;
        objc_setAssociatedObject(v, &kLGGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [g refresh];
    }
    g.hidden = !on;
    v.hidden = on;
    if (!on) return;
    CGRect f = v.frame;
    if (f.size.width < 10.0 || f.size.height < 10.0) return;
    g.frame = f;
    g.radius = LGSurfaceRadius(scope, f.size);
    if (g.superview != sv) {
        [sv insertSubview:g aboveSubview:v];
    } else {
        NSArray *subs = sv.subviews;
        if ([subs indexOfObject:g] != [subs indexOfObject:v] + 1) [sv insertSubview:g aboveSubview:v];
    }
}

// Hidden materials may not get their own layout pass, so the parents keep our glass in sync.
static void LGSyncSiblings(UIView *sv) {
    for (UIView *s in sv.subviews) {
        LGGlassView *g = LGExistingGlass(s);
        if (g && g.kind == LGKindSurface && g.superview == sv && !g.hidden && !CGRectIsEmpty(s.frame)) {
            g.frame = s.frame;
        }
    }
}

static void LGLayoutSurface(UIView *v, BOOL allowCC) {
    NSNumber *cached = objc_getAssociatedObject(v, &kLGScopeKey);
    LGScope scope = LGScopeNone;
    if (cached) {
        scope = (LGScope)[cached integerValue];
    } else {
        if (!v.window) return;
        CGSize s = v.bounds.size;
        if (s.width < 10.0 || s.height < 10.0) return; // wait for a real size
        scope = LGScopeForView(v, allowCC);
        if (scope != LGScopeNone && LGIsFullScreen(s)) scope = LGScopeNone; // full-screen backdrop
        objc_setAssociatedObject(v, &kLGScopeKey, @(scope), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (scope == LGScopeNone) return;

    if (scope != LGScopeCC) {
        LGLayoutSibling(v, scope);
        return;
    }

    // Control Center tile: glass sits on top of the system tile.
    LGGlassView *g = LGExistingGlass(v);
    if (!g) {
        if (!LG.cc) return;
        g = [[LGGlassView alloc] initWithKind:LGKindCC];
        g.host = v;
        objc_setAssociatedObject(v, &kLGGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:g];
        [g refresh];
    }
    g.hidden = !LG.cc;
    if (g.hidden) return;

    CGFloat r;
    if (LGHasSliderAncestor(v) && !LG.sliderCurved) {
        // Keep the system's own slider shape; reshaping it is what made the fill glitchy.
        r = v.layer.cornerRadius;
        if (r < 1.0) r = v.superview.layer.cornerRadius;
        if (r < 1.0) r = 19.0;
    } else {
        r = LGCCShapeRadius(v.bounds.size);
        LGApplyRadius(v, r, 4);
    }
    if (!CGRectEqualToRect(g.frame, v.bounds)) g.frame = v.bounds;
    g.radius = r;
    if (v.subviews.lastObject != g) [v bringSubviewToFront:g];
}

#pragma mark - Control Center sliders (iOS 26 style glyphs)

static char kLGGlyphKey;

static UIImage *LGDrawGlyph(CGSize size, void (^draw)(CGContextRef c)) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    draw(c);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static UIImage *LGSunImage(void) {
    static UIImage *img;
    if (img) return img;
    img = LGDrawGlyph(CGSizeMake(26.0, 26.0), ^(CGContextRef c) {
        UIColor *yellow = [UIColor colorWithRed:1.0 green:0.80 blue:0.04 alpha:1.0];
        CGContextSetFillColorWithColor(c, yellow.CGColor);
        CGContextSetStrokeColorWithColor(c, yellow.CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(13.0 - 4.8, 13.0 - 4.8, 9.6, 9.6));
        CGContextSetLineWidth(c, 2.0);
        for (int i = 0; i < 8; i++) {
            CGFloat a = i * M_PI / 4.0;
            CGContextMoveToPoint(c, 13.0 + cos(a) * 7.6, 13.0 + sin(a) * 7.6);
            CGContextAddLineToPoint(c, 13.0 + cos(a) * 10.4, 13.0 + sin(a) * 10.4);
            CGContextStrokePath(c);
        }
    });
    return img;
}

static UIImage *LGSpeakerImage(int waves) {
    static UIImage *cache[4];
    waves = MAX(0, MIN(3, waves));
    if (cache[waves]) return cache[waves];
    cache[waves] = LGDrawGlyph(CGSizeMake(28.0, 24.0), ^(CGContextRef c) {
        UIColor *blue = [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1.0];
        CGContextSetFillColorWithColor(c, blue.CGColor);
        CGContextSetStrokeColorWithColor(c, blue.CGColor);
        CGContextSetLineWidth(c, 1.4);
        CGContextMoveToPoint(c, 3.0, 9.5);
        CGContextAddLineToPoint(c, 7.2, 9.5);
        CGContextAddLineToPoint(c, 12.5, 5.0);
        CGContextAddLineToPoint(c, 12.5, 19.0);
        CGContextAddLineToPoint(c, 7.2, 14.5);
        CGContextAddLineToPoint(c, 3.0, 14.5);
        CGContextClosePath(c);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGContextSetLineWidth(c, 2.0);
        for (int i = 0; i < waves; i++) {
            CGFloat radius = 5.2 + 3.3 * i;
            CGContextAddArc(c, 12.0, 12.0, radius, -M_PI * 0.24, M_PI * 0.24, 0);
            CGContextStrokePath(c);
        }
    });
    return cache[waves];
}

// 1 = brightness, 2 = volume. Uses the owning view controllers' names, then position.
static int LGSliderKind(UIView *v) {
    for (UIResponder *r = v; r; r = r.nextResponder) {
        NSString *n = [NSStringFromClass([r class]) lowercaseString];
        if ([n containsString:@"volume"] || [n containsString:@"audio"] || [n containsString:@"sound"]) return 2;
        if ([n containsString:@"bright"] || [n containsString:@"display"]) return 1;
    }
    CGRect f = [v convertRect:v.bounds toView:nil];
    return CGRectGetMidX(f) < [UIScreen mainScreen].bounds.size.width / 2.0 ? 1 : 2;
}

// Hide every glyph-ish view the system slider owns (ivars and subviews named
// *glyph* / *package*, e.g. the animated CAPackage sun), so only our glyph shows.
// Returns the first one found so we can sit exactly where it was.
static UIView *LGHideSystemGlyphs(UIView *v, UIView *overlay) {
    UIView *first = nil;
    for (Class c = object_getClass(v); c && c != [UIView class] && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *list = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(list[i]);
            const char *nm = ivar_getName(list[i]);
            if (!t || t[0] != '@' || !nm) continue;
            NSString *lname = [[NSString stringWithUTF8String:nm] lowercaseString];
            if (![lname containsString:@"glyph"] && ![lname containsString:@"package"]) continue;
            id o = object_getIvar(v, list[i]);
            if ([o isKindOfClass:[UIView class]] && o != overlay) {
                UIView *gv = o;
                if (!first && !CGRectIsEmpty(gv.frame)) first = gv;
                gv.hidden = YES;
                gv.alpha = 0.0;
            }
        }
        free(list);
    }
    NSMutableArray *stack = [NSMutableArray arrayWithArray:v.subviews];
    int budget = 40;
    while (stack.count && budget-- > 0) {
        UIView *s = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if (s == overlay) continue;
        NSString *cn = [NSStringFromClass([s class]) lowercaseString];
        if ([cn containsString:@"glyph"] || [cn containsString:@"package"]) {
            if (!first && !CGRectIsEmpty(s.frame)) first = s;
            s.hidden = YES;
            s.alpha = 0.0;
        } else if (s.subviews.count && s.bounds.size.width < 200.0) {
            [stack addObjectsFromArray:s.subviews];
        }
    }
    return first;
}

static void LGLayoutSlider(UIView *v) {
    UIImageView *overlay = objc_getAssociatedObject(v, &kLGGlyphKey);
    if (!(LG.sliders && LG.cc)) {
        overlay.hidden = YES;
        return;
    }
    CGSize s = v.bounds.size;
    if (s.width < 10.0 || s.height < 10.0) return;
    if (!overlay) {
        overlay = [[UIImageView alloc] initWithFrame:CGRectZero];
        overlay.userInteractionEnabled = NO;
        overlay.contentMode = UIViewContentModeCenter;
        objc_setAssociatedObject(v, &kLGGlyphKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:overlay];
    }
    UIView *sys = LGHideSystemGlyphs(v, overlay);

    int kind = LGSliderKind(v);
    double value = 0.5;
    if ([v respondsToSelector:@selector(value)]) {
        @try { value = [[v valueForKey:@"value"] doubleValue]; } @catch (__unused NSException *e) {}
    }
    int waves = value <= 0.001 ? 0 : (value < 0.34 ? 1 : (value < 0.67 ? 2 : 3));
    UIImage *img = (kind == 1) ? LGSunImage() : LGSpeakerImage(waves);
    if (overlay.image != img) overlay.image = img;

    CGSize gs = img.size;
    CGPoint c = CGPointMake(s.width / 2.0, s.height - 34.0);
    if (sys && sys.superview) {
        c = [v convertPoint:CGPointMake(CGRectGetMidX(sys.bounds), CGRectGetMidY(sys.bounds)) fromView:sys];
    }
    CGRect f = CGRectMake(c.x - gs.width / 2.0, c.y - gs.height / 2.0, gs.width, gs.height);
    if (!CGRectEqualToRect(overlay.frame, f)) overlay.frame = f;
    overlay.hidden = NO;
    if (v.subviews.lastObject != overlay) [v bringSubviewToFront:overlay];
}

#pragma mark - Status bar (iOS 26 battery / Wi-Fi / signal)

@protocol LGLegibilityFactory
+ (id)imageFromImage:(UIImage *)image withShadowImage:(UIImage *)shadow;
@end

static BOOL LGIvarInt(id obj, const char *name, int *out) {
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    const char *t = ivar_getTypeEncoding(iv);
    if (!t) return NO;
    char *base = (char *)(__bridge void *)obj + ivar_getOffset(iv);
    switch (t[0]) {
        case 'i': *out = *(int *)base; return YES;
        case 'I': *out = (int)*(unsigned int *)base; return YES;
        case 's': *out = *(short *)base; return YES;
        case 'S': *out = *(unsigned short *)base; return YES;
        case 'q': *out = (int)*(long long *)base; return YES;
        case 'Q': *out = (int)*(unsigned long long *)base; return YES;
        case 'c': *out = *(signed char *)base; return YES;
        case 'C': *out = *(unsigned char *)base; return YES;
        default:  return NO;
    }
}

// Is the original status bar glyph light (white style) or dark (black style)?
static BOOL LGImageIsLight(UIImage *img) {
    if (!img.CGImage) return YES;
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return YES;
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(c);
    if (px[3] == 0) return YES;
    CGFloat lum = (0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]) / (CGFloat)px[3];
    return lum > 0.5;
}

static UIImage *LGBatteryImage(CGFloat level, BOOL charging, BOOL lowPower, BOOL light) {
    const CGFloat W = 27.0, H = 12.5;
    UIColor *fg = light ? [UIColor whiteColor] : [UIColor blackColor];
    UIColor *fill = fg;
    if (charging) fill = [UIColor colorWithRed:0.20 green:0.82 blue:0.35 alpha:1.0];
    else if (lowPower) fill = [UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1.0];
    else if (level <= 0.20) fill = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    return LGDrawGlyph(CGSizeMake(W, H), ^(CGContextRef c) {
        UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, W, H) cornerRadius:H / 2.0];
        CGContextSetFillColorWithColor(c, [fg colorWithAlphaComponent:0.32].CGColor);
        CGContextAddPath(c, pill.CGPath);
        CGContextFillPath(c);
        CGContextSaveGState(c);
        CGContextAddPath(c, pill.CGPath);
        CGContextClip(c);
        CGContextSetFillColorWithColor(c, fill.CGColor);
        CGContextFillRect(c, CGRectMake(0, 0, MAX(level, 0.06) * W, H));
        CGContextRestoreGState(c);
    });
}

static UIImage *LGWifiImage(int bars, BOOL light) {
    const CGFloat W = 19.0, H = 14.0;
    UIColor *fg = light ? [UIColor whiteColor] : [UIColor blackColor];
    return LGDrawGlyph(CGSizeMake(W, H), ^(CGContextRef c) {
        CGPoint o = CGPointMake(W / 2.0, H - 2.0);
        for (int i = 0; i < 3; i++) {
            CGContextSetStrokeColorWithColor(c, [fg colorWithAlphaComponent:(i < bars ? 1.0 : 0.32)].CGColor);
            CGContextSetLineWidth(c, 2.5);
            CGFloat r = 4.1 + 3.3 * i;
            CGContextAddArc(c, o.x, o.y, r, -M_PI * 0.75, -M_PI * 0.25, 0);
            CGContextStrokePath(c);
        }
        CGContextSetFillColorWithColor(c, [fg colorWithAlphaComponent:(bars > 0 ? 1.0 : 0.32)].CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(o.x - 1.9, o.y - 1.9, 3.8, 3.8));
    });
}

static UIImage *LGSignalImage(int bars, BOOL light) {
    const CGFloat bw = 3.3, gap = 1.6, H = 13.5;
    UIColor *fg = light ? [UIColor whiteColor] : [UIColor blackColor];
    return LGDrawGlyph(CGSizeMake(4 * bw + 3 * gap, H), ^(CGContextRef c) {
        const CGFloat heights[4] = {4.6, 7.6, 10.6, 13.5};
        for (int i = 0; i < 4; i++) {
            CGRect r = CGRectMake(i * (bw + gap), H - heights[i], bw, heights[i]);
            CGContextSetFillColorWithColor(c, [fg colorWithAlphaComponent:(i < bars ? 1.0 : 0.32)].CGColor);
            CGContextAddPath(c, [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:1.2].CGPath);
            CGContextFillPath(c);
        }
    });
}

// Wrap a replacement image the way the original was returned (plain image or legibility set).
static id LGWrapLike(id orig, UIImage *img) {
    if (!img) return orig;
    if ([orig isKindOfClass:[UIImage class]]) return img;
    Class<LGLegibilityFactory> f = (Class<LGLegibilityFactory>)[orig class];
    if (![(Class)f respondsToSelector:@selector(imageFromImage:withShadowImage:)]) return orig;
    UIImage *shadow = LGDrawGlyph(img.size, ^(CGContextRef c) {});
    id set = nil;
    @try { set = [f imageFromImage:img withShadowImage:shadow]; } @catch (__unused NSException *e) {}
    return set ?: orig;
}

static UIImage *LGOrigImage(id orig) {
    if ([orig isKindOfClass:[UIImage class]]) return orig;
    if ([orig respondsToSelector:@selector(image)]) {
        id i = [orig performSelector:@selector(image)];
        if ([i isKindOfClass:[UIImage class]]) return i;
    }
    return nil;
}

#pragma mark - Hooks (SpringBoard)

%group SB

%hook SBFloatingDockPlatterView

- (void)layoutSubviews {
    %orig;
    UIView *bg = LGViewForKey(self, @"_backgroundView") ?: LGViewForKey(self, @"backgroundView");
    CGRect b = self.bounds;
    LGLayoutDock(self, bg, b, MIN(b.size.height * 0.31, 36.0), YES);
}

%end

%hook SBDockView

- (void)layoutSubviews {
    %orig;
    UIView *bg = LGViewForKey(self, @"_backgroundView");
    if (!bg || CGRectIsEmpty(bg.frame)) return;
    CGRect r = CGRectInset(bg.frame, 10.0, 8.0);
    if (r.size.height <= 0 || r.size.width <= 0) return;
    LGLayoutDock(self, bg, r, MIN(r.size.height / 2.0, 34.0), NO);
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
    LGLayoutSurface(self, YES);
}

- (void)layoutSubviews {
    %orig;
    LGLayoutSurface(self, YES);
}

%end

%hook UIVisualEffectView

- (void)layoutSubviews {
    %orig;
    LGInstallDimIfNeeded(self);
    LGLayoutSurface(self, NO);
}

%end

%hook _UIBackdropView

- (void)layoutSubviews {
    %orig;
    LGInstallDimIfNeeded(self);
    LGLayoutSurface(self, NO);
}

%end

%hook SBFolderIconBackgroundView

- (void)layoutSubviews {
    %orig;
    LGSyncSiblings(self);
}

%end

%hook SBFolderBackgroundView

- (void)layoutSubviews {
    %orig;
    LGSyncSiblings(self);
}

%end

%hook SBFolderIconImageView

- (void)layoutSubviews {
    %orig;
    LGSyncSiblings(self);
}

%end

%hook WGWidgetPlatterView

- (void)layoutSubviews {
    %orig;
    LGSyncSiblings(self);
}

%end

%hook CCUIContinuousSliderView

- (void)layoutSubviews {
    %orig;
    LGLayoutSlider(self);
}

%end

%hook CCUIModuleSliderView

- (void)layoutSubviews {
    %orig;
    LGLayoutSlider(self);
}

%end

%end // group SB

#pragma mark - Hooks (status bar, runs in every UIKit app)

%group StatusBar

%hook UIStatusBarBatteryItemView

- (id)contentsImage {
    id orig = %orig;
    UIImage *oi = LGOrigImage(orig);
    if (!LG.statusBar || !oi) return orig;
    UIDevice *d = [UIDevice currentDevice];
    if (!d.batteryMonitoringEnabled) d.batteryMonitoringEnabled = YES;
    if (d.batteryLevel < 0.0f) return orig;
    BOOL charging = (d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull);
    UIImage *img = LGBatteryImage(d.batteryLevel, charging,
                                  [NSProcessInfo processInfo].isLowPowerModeEnabled, LGImageIsLight(oi));
    return LGWrapLike(orig, img);
}

%end

%hook UIStatusBarDataNetworkItemView

- (id)contentsImage {
    id orig = %orig;
    UIImage *oi = LGOrigImage(orig);
    if (!LG.statusBar || !oi) return orig;
    int type = -1;
    if (!LGIvarInt(self, "_dataNetworkType", &type) || type != 5) return orig; // 5 = Wi-Fi
    int bars = 3;
    LGIvarInt(self, "_wifiStrengthBars", &bars);
    bars = MAX(0, MIN(3, bars));
    return LGWrapLike(orig, LGWifiImage(bars, LGImageIsLight(oi)));
}

%end

%hook UIStatusBarSignalStrengthItemView

- (id)contentsImage {
    id orig = %orig;
    UIImage *oi = LGOrigImage(orig);
    if (!LG.statusBar || !oi) return orig;
    int n = -1;
    if (!LGIvarInt(self, "_signalStrengthBars", &n)) return orig;
    n = MAX(0, MIN(5, n));
    int bars = (int)lround(n * 4.0 / 5.0);
    return LGWrapLike(orig, LGSignalImage(bars, LGImageIsLight(oi)));
}

%end

%end // group StatusBar

#pragma mark - Live preference updates

static void LGPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLoadPrefs();
        for (LGGlassView *g in [LGRegistry allObjects]) {
            [g refresh];
            UIView *h = g.host;
            if (g.kind == LGKindSurface && h) {
                LGLayoutSibling(h, (LGScope)[objc_getAssociatedObject(h, &kLGScopeKey) integerValue]);
            }
            [h setNeedsLayout];
        }
        for (UIView *dim in [LGDimRegistry allObjects]) {
            LGUpdateDim(dim);
            [dim.superview setNeedsLayout];
        }
    });
}

static BOOL LGClassResponds(const char *cls, SEL sel) {
    Class c = objc_getClass(cls);
    return c && class_getInstanceMethod(c, sel) != NULL;
}

%ctor {
    @autoreleasepool {
        LGLoadPrefs();
        BOOL isSB = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];

        if (isSB) {
            %init(SB);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                            LGPrefsChanged, LG_NOTIFY, NULL,
                                            CFNotificationSuspensionBehaviorCoalesce);
        }

        // Status bar glyphs are drawn inside each app, so these hooks load everywhere,
        // but only when the item views really have the method we replace.
        if (LG.statusBar &&
            LGClassResponds("UIStatusBarBatteryItemView", @selector(contentsImage)) &&
            LGClassResponds("UIStatusBarDataNetworkItemView", @selector(contentsImage)) &&
            LGClassResponds("UIStatusBarSignalStrengthItemView", @selector(contentsImage))) {
            %init(StatusBar);
        }
    }
}
