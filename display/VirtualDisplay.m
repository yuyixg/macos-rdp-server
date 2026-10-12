#import "display/VirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
#import <pthread.h>
#import <dlfcn.h>
#define RDP_LOG_COMPONENT "display"
#include "logging/RDPLog.h"

@interface VirtualDisplay ()
@property (nonatomic, assign) CGDirectDisplayID did;
@property (nonatomic, assign) uint32_t w;
@property (nonatomic, assign) uint32_t h;
@property (nonatomic, assign) BOOL created;
@property (nonatomic, assign) uint64_t layoutGen;   /* 0 = never arranged displays */
@property (nonatomic, assign) BOOL hidpi;           /* _w x _h are points, backed @2x */

#if MACOS_RDP_VIRTUAL_DISPLAY
/* Opaque pointers so the compiler doesn't need CGVirtualDisplay headers here.
 * CGVirtualDisplay and its private VirtualDisplayListener thread keep using the
 * descriptor/mode/settings objects AFTER applySettings: returns, so all of them
 * must be retained for the display's whole lifetime — otherwise they dealloc when
 * createVirtualDisplay returns and the listener thread crashes on freed memory. */
@property (nonatomic, strong) id vdObject;
@property (nonatomic, strong) id vdDescriptor;
@property (nonatomic, strong) id vdMode;
@property (nonatomic, strong) id vdSettings;
#endif
@end

#if MACOS_RDP_VIRTUAL_DISPLAY
/* ── Physical display layout during a session (local patch) ───────────────
 * Upstream only moved the old main display aside, which overlapped any second
 * monitor, never restored the layout, and left already-open windows on the
 * physical screen where the remote user can't see them.
 *
 * RDP_DISPLAY_MODE=disable (default): physical displays are switched off for
 *   the session (private CGSConfigureDisplayEnabled), so every window moves to
 *   the virtual display, which keeps the client's full resolution. The IDs are
 *   persisted to ~/.macos-rdp/disabled-displays and re-enabled at daemon start,
 *   so a crash can't leave the monitor dark.
 * RDP_DISPLAY_MODE=mirror: physical displays mirror the virtual display. macOS
 *   forces one backing resolution for a mirror set, so the virtual display is
 *   limited to the monitor's resolution.
 * RDP_DISPLAY_MODE=extend: physical displays are shifted, as a block, to the
 *   right of the virtual display (separate empty desktop for the remote user).
 *
 * The original arrangement is saved and put back on destroy. Uses the ONLINE
 * display list so sleeping displays (e.g. after screen lock) count. */
#define MAX_SAVED_DISPLAYS 16
static CGDirectDisplayID g_savedIDs[MAX_SAVED_DISPLAYS];
static CGRect            g_savedBounds[MAX_SAVED_DISPLAYS];
static uint32_t          g_savedCount = 0;
static BOOL              g_mirrored = NO;
static BOOL              g_disabled = NO;
/* On a reconnect (takeover) the old session's -destroy can run while the new
 * session is arranging displays. Serialise both, and let only the newest
 * session (highest generation) restore the layout. */
static pthread_mutex_t   g_layoutLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t          g_layoutGen = 0;

typedef enum { DISPLAY_MODE_DISABLE, DISPLAY_MODE_MIRROR, DISPLAY_MODE_EXTEND } DisplayMode;

static DisplayMode display_mode(void) {
    const char *m = getenv("RDP_DISPLAY_MODE");
    if (m && strcmp(m, "mirror") == 0) return DISPLAY_MODE_MIRROR;
    if (m && strcmp(m, "extend") == 0) return DISPLAY_MODE_EXTEND;
    return DISPLAY_MODE_DISABLE;
}

/* Private SkyLight/CoreGraphics call, resolved at runtime so a missing symbol
 * just falls back to extend instead of failing to load. */
typedef CGError (*CGSConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static CGSConfigureDisplayEnabledFn display_enable_fn(void) {
    static CGSConfigureDisplayEnabledFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (CGSConfigureDisplayEnabledFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    });
    return fn;
}

static NSString *disabled_state_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".macos-rdp/disabled-displays"];
}

/* Enable/disable a set of displays in one transaction. */
static CGError set_displays_enabled(const CGDirectDisplayID *ids, uint32_t n, bool enabled) {
    CGSConfigureDisplayEnabledFn fn = display_enable_fn();
    if (!fn || n == 0) return kCGErrorFailure;
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return kCGErrorFailure;
    for (uint32_t i = 0; i < n; i++) fn(cfg, ids[i], enabled);
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
}

/* Switch a display to its HiDPI mode that looks like w x h points (2w x 2h
 * pixels). Returns YES if that mode is (now) active. */
static BOOL select_hidpi_mode(CGDirectDisplayID did, uint32_t w, uint32_t h) {
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    BOOL already = cur && CGDisplayModeGetWidth(cur) == w && CGDisplayModeGetHeight(cur) == h &&
                   CGDisplayModeGetPixelWidth(cur) == 2 * w;
    if (cur) CGDisplayModeRelease(cur);
    if (already) return YES;

    NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);
    if (!modes) return NO;
    CGDisplayModeRef pick = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(m) == w && CGDisplayModeGetHeight(m) == h &&
            CGDisplayModeGetPixelWidth(m) == 2 * w) { pick = m; break; }
    }
    BOOL ok = NO;
    if (pick) {
        CGDisplayConfigRef cfg = NULL;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(cfg, did, pick, NULL);
            ok = (CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) == kCGErrorSuccess);
        }
    }
    CFRelease(modes);
    rdp_info("virtual display %u: HiDPI %ux%u@2x mode %s", did, w, h,
             !pick ? "NOT offered by macOS" : (ok ? "selected" : "select failed"));
    return ok;
}

/* Caller holds g_layoutLock. */
static void apply_session_layout_locked(CGDirectDisplayID vdid, uint32_t vw, uint32_t vh,
                                        BOOL hidpi) {
    if (g_savedCount > 0) {
        /* A previous session is still being torn down: its saved list is the
         * ORIGINAL arrangement — keep it rather than snapshotting the
         * mirrored/shifted state it left behind. */
        rdp_info("virtual display %u: taking over original layout of %u display(s) "
                 "from previous session", vdid, g_savedCount);
    } else {
        CGDirectDisplayID online[MAX_SAVED_DISPLAYS];
        uint32_t n = 0;
        CGGetOnlineDisplayList(MAX_SAVED_DISPLAYS, online, &n);
        for (uint32_t i = 0; i < n; i++) {
            CGDirectDisplayID d = online[i];
            CGDirectDisplayID m = CGDisplayMirrorsDisplay(d);
            /* Skip ourselves and displays in a user-made mirror set (they
             * follow their own master). */
            if (d == vdid || (m != kCGNullDirectDisplay && m != vdid)) continue;
            g_savedIDs[g_savedCount] = d;
            g_savedBounds[g_savedCount] = CGDisplayBounds(d);
            g_savedCount++;
        }
    }
    g_mirrored = NO;
    double minX = 0;
    for (uint32_t i = 0; i < g_savedCount; i++)
        if (i == 0 || g_savedBounds[i].origin.x < minX) minX = g_savedBounds[i].origin.x;
    if (g_savedCount == 0) {
        rdp_info("virtual display %u: no physical displays online — nothing to arrange", vdid);
        return;
    }

    CGDisplayConfigRef cfg = NULL;
    CGError ce = kCGErrorFailure;
    g_disabled = NO;
    if (display_mode() == DISPLAY_MODE_DISABLE) {
        if (!display_enable_fn()) {
            rdp_error("CGSConfigureDisplayEnabled unavailable — falling back to extend");
        } else {
            /* Persist first: if we die after disabling, startup re-enables. */
            NSMutableString *ids = [NSMutableString string];
            for (uint32_t i = 0; i < g_savedCount; i++) [ids appendFormat:@"%u\n", g_savedIDs[i]];
            [ids writeToFile:disabled_state_path() atomically:YES encoding:NSUTF8StringEncoding error:NULL];

            ce = set_displays_enabled(g_savedIDs, g_savedCount, false);
            if (ce == kCGErrorSuccess) {
                g_disabled = YES;
                /* A display that was asleep may come back when it wakes. */
                usleep(2000000);
                uint32_t stillActive = 0;
                for (uint32_t i = 0; i < g_savedCount; i++)
                    if (CGDisplayIsActive(g_savedIDs[i])) stillActive++;
                if (stillActive > 0) {
                    ce = set_displays_enabled(g_savedIDs, g_savedCount, false);
                    rdp_info("disable check: %u display(s) still active — re-applied (rc=%d)",
                             stillActive, ce);
                }
                if (hidpi) select_hidpi_mode(vdid, vw, vh);
                CGSize vb = CGDisplayBounds(vdid).size;
                CGDisplayModeRef vm = CGDisplayCopyDisplayMode(vdid);
                rdp_info("virtual display %u is the only display; %u physical display(s) "
                         "disabled for the session (%.0fx%.0f points, %zux%zu pixels)",
                         vdid, g_savedCount, vb.width, vb.height,
                         vm ? CGDisplayModeGetPixelWidth(vm) : 0,
                         vm ? CGDisplayModeGetPixelHeight(vm) : 0);
                if (vm) CGDisplayModeRelease(vm);
                return;
            }
            [[NSFileManager defaultManager] removeItemAtPath:disabled_state_path() error:NULL];
            rdp_error("disabling %u physical display(s) failed (rc=%d) — falling back to extend",
                      g_savedCount, ce);
        }
    }
    if (display_mode() == DISPLAY_MODE_MIRROR) {
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(cfg, vdid, 0, 0);
            for (uint32_t i = 0; i < g_savedCount; i++)
                CGConfigureDisplayMirrorOfDisplay(cfg, g_savedIDs[i], vdid);
            ce = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        if (ce == kCGErrorSuccess) {
            g_mirrored = YES;
            rdp_info("virtual display %u set as main; %u physical display(s) now mirror it (rc=0)",
                     vdid, g_savedCount);
            /* A display that was asleep can drop out of the mirror set when it
             * wakes. Verify, and re-apply once if needed. */
            usleep(2000000);
            uint32_t notMirroring = 0;
            for (uint32_t i = 0; i < g_savedCount; i++)
                if (CGDisplayIsOnline(g_savedIDs[i]) &&
                    CGDisplayMirrorsDisplay(g_savedIDs[i]) != vdid) notMirroring++;
            if (notMirroring > 0 && CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
                for (uint32_t i = 0; i < g_savedCount; i++)
                    CGConfigureDisplayMirrorOfDisplay(cfg, g_savedIDs[i], vdid);
                ce = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
                rdp_info("mirror check: %u display(s) had dropped out — re-applied (rc=%d)",
                         notMirroring, ce);
            }
            /* Mirroring may have switched the virtual display off its HiDPI mode. */
            if (hidpi) select_hidpi_mode(vdid, vw, vh);
            CGSize vb = CGDisplayBounds(vdid).size;
            CGDisplayModeRef vm = CGDisplayCopyDisplayMode(vdid);
            rdp_info("mirror check: virtual display %u is %.0fx%.0f points, %zux%zu pixels",
                     vdid, vb.width, vb.height,
                     vm ? CGDisplayModeGetPixelWidth(vm) : 0, vm ? CGDisplayModeGetPixelHeight(vm) : 0);
            if (vm) CGDisplayModeRelease(vm);
            /* If macOS forced a common mode (seen: 2560x1600, 16:10, on a 16:9
             * client) the picture is distorted and the pointer is off. Never
             * stay in that state: unmirror and extend instead. */
            if ((uint32_t)vb.width == vw && (uint32_t)vb.height == vh) return;
            rdp_error("mirror check: macOS changed virtual display to %.0fx%.0f (wanted %ux%u) "
                      "— un-mirroring, falling back to extend", vb.width, vb.height, vw, vh);
            if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
                for (uint32_t i = 0; i < g_savedCount; i++)
                    CGConfigureDisplayMirrorOfDisplay(cfg, g_savedIDs[i], kCGNullDirectDisplay);
                CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            }
            g_mirrored = NO;
            usleep(500000);
            if (hidpi) select_hidpi_mode(vdid, vw, vh);
        } else {
            rdp_error("mirroring %u physical display(s) to virtual display %u failed (rc=%d) "
                      "— falling back to extend", g_savedCount, vdid, ce);
        }
    }

    /* Extend: shift every physical display right of the virtual one, keeping
     * their relative arrangement so multi-monitor setups don't overlap. */
    CGPoint mainOrigin = CGDisplayBounds(CGMainDisplayID()).origin;
    double shiftX = (double)vw - minX;
    double shiftY = -mainOrigin.y;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    CGConfigureDisplayOrigin(cfg, vdid, 0, 0);
    for (uint32_t i = 0; i < g_savedCount; i++)
        CGConfigureDisplayOrigin(cfg, g_savedIDs[i],
                                 (int32_t)(g_savedBounds[i].origin.x + shiftX),
                                 (int32_t)(g_savedBounds[i].origin.y + shiftY));
    ce = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    rdp_info("virtual display %u set as main; %u physical display(s) shifted right by %.0f (rc=%d)",
             vdid, g_savedCount, shiftX, ce);
}

/* Returns this session's layout generation, to pass back to restore. */
static uint64_t apply_session_layout(CGDirectDisplayID vdid, uint32_t vw, uint32_t vh,
                                     BOOL hidpi) {
    pthread_mutex_lock(&g_layoutLock);
    uint64_t gen = ++g_layoutGen;
    apply_session_layout_locked(vdid, vw, vh, hidpi);
    pthread_mutex_unlock(&g_layoutLock);
    return gen;
}

/* Caller holds g_layoutLock. */
static void restore_saved_layout_locked(CGDirectDisplayID vdid) {
    if (g_savedCount == 0) return;
    if (g_disabled) {
        /* Re-enable BEFORE the virtual display goes away (first call), so there
         * is never a moment with no display at all; retried on the second call
         * if that failed. A failure leaves the state file for startup recovery. */
        CGError ee = set_displays_enabled(g_savedIDs, g_savedCount, true);
        rdp_info("re-enabled %u physical display(s) (rc=%d)", g_savedCount, ee);
        if (ee == kCGErrorSuccess) {
            [[NSFileManager defaultManager] removeItemAtPath:disabled_state_path() error:NULL];
            g_disabled = NO;
        }
        usleep(500000);
    }
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    double maxRight = 0;
    for (uint32_t i = 0; i < g_savedCount; i++) {
        CGDirectDisplayID d = g_savedIDs[i];
        CGRect b = g_savedBounds[i];
        if (b.origin.x + b.size.width > maxRight) maxRight = b.origin.x + b.size.width;
        if (!CGDisplayIsOnline(d)) continue;
        if (g_mirrored) CGConfigureDisplayMirrorOfDisplay(cfg, d, kCGNullDirectDisplay);
        CGConfigureDisplayOrigin(cfg, d, (int32_t)b.origin.x, (int32_t)b.origin.y);
    }
    if (vdid != 0) CGConfigureDisplayOrigin(cfg, vdid, (int32_t)maxRight, 0);
    CGError ce = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (vdid == 0) {
        rdp_info("restored original layout of %u physical display(s)%s (rc=%d)",
                 g_savedCount, g_mirrored ? ", mirroring off" : "", ce);
        g_savedCount = 0;
        g_mirrored = NO;
        g_disabled = NO;
    }
}

/* Startup recovery: re-enable displays a previous (crashed/killed) instance
 * disabled. Cheap no-op when the state file is absent. */
static void recover_disabled_displays(void) {
    NSString *s = [NSString stringWithContentsOfFile:disabled_state_path()
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (!s) return;
    CGDirectDisplayID ids[MAX_SAVED_DISPLAYS];
    uint32_t n = 0;
    for (NSString *line in [s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0 || n >= MAX_SAVED_DISPLAYS) continue;
        ids[n++] = (CGDirectDisplayID)strtoul(line.UTF8String, NULL, 10);
    }
    CGError ce = set_displays_enabled(ids, n, true);
    rdp_info("startup: re-enabled %u display(s) left disabled by a previous run (rc=%d)", n, ce);
    if (ce == kCGErrorSuccess)
        [[NSFileManager defaultManager] removeItemAtPath:disabled_state_path() error:NULL];
}

/* Put physical displays back where they were. Called twice from -destroy:
 * once while the virtual display still exists (vdid != 0: unmirror and park
 * the virtual display out of the way, so a physical display reclaims (0,0)),
 * and once after it is gone (vdid == 0) to settle any shuffle WindowServer did.
 * A no-op if a newer session has taken over the layout. */
static void restore_saved_layout(CGDirectDisplayID vdid, uint64_t gen) {
    pthread_mutex_lock(&g_layoutLock);
    if (gen != 0 && gen == g_layoutGen) {
        restore_saved_layout_locked(vdid);
    } else if (vdid == 0 && g_savedCount > 0) {
        rdp_info("display layout now owned by a newer session — not restoring");
    }
    pthread_mutex_unlock(&g_layoutLock);
}
#endif

@implementation VirtualDisplay

+ (void)recoverDisabledDisplays {
#if MACOS_RDP_VIRTUAL_DISPLAY
    recover_disabled_displays();
#endif
}

- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
    if ((self = [super init])) {
        _w = width;
        _h = height;
    }
    return self;
}

- (CGDirectDisplayID)displayID { return _did; }
- (uint32_t)width              { return _w; }
- (uint32_t)height             { return _h; }

- (BOOL)create {
    if (_created) return YES;

#if MACOS_RDP_VIRTUAL_DISPLAY
    [self createVirtualDisplay];
#else
    /* Default: capture the main display. Physical display is undisturbed
       because RDP sessions run in a separate window-server context when
       the daemon is launched as a login item for a specific user. */
    _did = CGMainDisplayID();
    rdp_info("using main display %u (%ux%u) — build with MACOS_RDP_VIRTUAL_DISPLAY=1 "
             "for a dedicated virtual display (requires Apple entitlement)", _did, _w, _h);
#endif

    _created = YES;
    return YES;
}

- (void)destroy {
    if (!_created) return;
#if MACOS_RDP_VIRTUAL_DISPLAY
    /* Unmirror / move physical displays back while the virtual one still exists. */
    restore_saved_layout(_did, _layoutGen);
    /* Release in reverse dependency order: drop the display first (stops its
     * listener thread), then the settings/mode/descriptor it referenced. */
    _vdObject     = nil;
    _vdSettings   = nil;
    _vdMode       = nil;
    _vdDescriptor = nil;
    /* Let WindowServer drop the virtual display, then settle the layout. */
    usleep(300000);
    restore_saved_layout(0, _layoutGen);
    _layoutGen = 0;
#endif
    _did = 0;
    _created = NO;
    rdp_verbose("display released");
}

- (void)setResolutionWidth:(uint32_t)width height:(uint32_t)height {
    _w = width;
    _h = height;
    rdp_verbose("resolution set to %ux%u (takes effect on next session)", width, height);
}

#if MACOS_RDP_VIRTUAL_DISPLAY
- (void)createVirtualDisplay {
    /*
     * Create a CGVirtualDisplay sized exactly to the RDP client (e.g. 3440x1440)
     * so there is no pillarbox/scaling and pointer mapping is 1:1. CGVirtualDisplay
     * is a PRIVATE CoreGraphics API (CGVirtualDisplayDescriptor / *Mode / *Settings),
     * driven here entirely via NSClassFromString + KVC + NSInvocation so a missing
     * class / wrong ABI / thrown exception cleanly falls back to the main display
     * (pillarboxed) instead of crashing the daemon.
     */
    _did = CGMainDisplayID();   /* safe default */

    /* Local patch: in mirror mode, size the virtual display to the physical main
     * display. Mirroring two displays with different resolutions makes macOS
     * force a common mode (seen: 3840x2160 + 1920x1080 -> 2560x1600, 16:10),
     * which breaks capture scaling and pointer mapping. Capture still encodes at
     * the client's size (upscaled) and input maps proportionally. */
    /* When the client has ~2x the physical pixels (e.g. 4K client, 1080p monitor)
     * make it HiDPI: same point size as the monitor (so mirroring keeps it), but
     * rendered at 2x so the client gets full-resolution text. */
    _hidpi = NO;
    if (display_mode() != DISPLAY_MODE_MIRROR) {
        /* Disable/extend: keep the client's resolution. For a 4K-class client
         * default to HiDPI (half-size points @2x) so the UI isn't tiny; set
         * RDP_HIDPI=0 for a 1:1 full-resolution desktop. */
        const char *hd = getenv("RDP_HIDPI");
        BOOL wantHiDPI = hd ? (hd[0] == '1') : (_w >= 3200);
        if (wantHiDPI && _w >= 1280 && _h >= 720) {
            _hidpi = YES;
            rdp_info("virtual display %ux%u points @2x HiDPI (client %ux%u)",
                     _w / 2, _h / 2, _w, _h);
            _w /= 2;
            _h /= 2;
        }
    } else if (_did != kCGNullDirectDisplay) {
        CGSize phys = CGDisplayBounds(_did).size;
        uint32_t pw = (uint32_t)phys.width, ph = (uint32_t)phys.height;
        if (pw >= 640 && ph >= 480) {
            _hidpi = (_w >= pw * 3 / 2 && _h >= ph * 3 / 2);
            if (pw != _w || ph != _h) {
                rdp_info("mirror mode: virtual display %ux%u points%s to match physical main "
                         "(client %ux%u)", pw, ph, _hidpi ? " @2x HiDPI" : " (scaled)", _w, _h);
                _w = pw;
                _h = ph;
            }
        }
    }
    const uint32_t scale = _hidpi ? 2 : 1;

    @try {
        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class dispClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class setClass  = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!descClass || !dispClass || !modeClass || !setClass) {
            rdp_error("CGVirtualDisplay classes unavailable on this macOS — "
                      "using main display (pillarboxed)");
            return;
        }

        id desc = [[descClass alloc] init];
        [desc setValue:@"RDP Virtual Display" forKey:@"name"];
        [desc setValue:@(_w * scale) forKey:@"maxPixelsWide"];
        [desc setValue:@(_h * scale) forKey:@"maxPixelsHigh"];
        double dpi = 100.0;
        CGSize mm = CGSizeMake((_w / dpi) * 25.4, (_h / dpi) * 25.4);
        [desc setValue:[NSValue valueWithBytes:&mm objCType:@encode(CGSize)]
                forKey:@"sizeInMillimeters"];
        @try { [desc setValue:@(0x5244500u) forKey:@"productID"]; } @catch (id e) {}
        @try { [desc setValue:@(0x5244500u) forKey:@"vendorID"];  } @catch (id e) {}
        /* Local patch: alternate serial 1/2 so a takeover session's display gets
         * a different ID from the one the old session is still releasing. */
        static uint32_t serialCounter = 0;
        uint32_t serial = (__atomic_fetch_add(&serialCounter, 1, __ATOMIC_RELAXED) % 2) + 1;
        @try { [desc setValue:@(serial)     forKey:@"serialNum"]; } @catch (id e) {}
        @try { [desc setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                       forKey:@"queue"]; } @catch (id e) {}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vd = [[dispClass alloc] performSelector:@selector(initWithDescriptor:)
                                         withObject:desc];
#pragma clang diagnostic pop
        if (!vd) { rdp_error("CGVirtualDisplay init failed — main display"); return; }

        /* Build a mode via NSInvocation (scalar args). Signature is assumed
         * (unsigned int width, unsigned int height, double refreshRate).
         *
         * initWithWidth:... is an init-family method: it initialises the alloc'd
         * receiver in place and returns self. We deliberately use the alloc'd
         * object `m` directly rather than reading getReturnValue + __bridge — that
         * earlier pattern gave ARC two independent strong references (m and the
         * bridged return) to one +1 object and over-released it (SIGSEGV in
         * objc_release). With a single strong `m`, ARC owns exactly one +1. */
        id mode = nil;
        SEL modeSel = @selector(initWithWidth:height:refreshRate:);
        if ([modeClass instancesRespondToSelector:modeSel]) {
            id m = [modeClass alloc];
            NSMethodSignature *sig = [m methodSignatureForSelector:modeSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = m; inv.selector = modeSel;
            /* Mode size is in POINTS. With hiDPI=1 and maxPixels at 2x, macOS
             * offers it as a Retina "looks like _w x _h" mode backed by 2x
             * pixels. (Passing the 2x size here yields only a 1x mode.) */
            unsigned int w = _w, h = _h; double rr = 60.0;
            [inv setArgument:&w atIndex:2];
            [inv setArgument:&h atIndex:3];
            [inv setArgument:&rr atIndex:4];
            [inv invoke];                 /* initialises m in place, returns self */
            mode = m;
        }
        if (!mode) { rdp_error("CGVirtualDisplayMode init failed — main display"); return; }

        id settings = [[setClass alloc] init];
        [settings setValue:@[mode] forKey:@"modes"];
        @try { [settings setValue:@(_hidpi ? 1 : 0) forKey:@"hiDPI"]; } @catch (id e) {}

        BOOL applied = NO;
        SEL applySel = @selector(applySettings:);
        if ([vd respondsToSelector:applySel]) {
            NSMethodSignature *sig2 = [vd methodSignatureForSelector:applySel];
            NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
            inv2.target = vd; inv2.selector = applySel;
            [inv2 setArgument:&settings atIndex:2];
            [inv2 retainArguments];   /* NSInvocation won't outlive `settings` otherwise */
            [inv2 invoke];
            [inv2 getReturnValue:&applied];
        }

        CGDirectDisplayID vdid = 0;
        @try { vdid = (CGDirectDisplayID)[[vd valueForKey:@"displayID"] unsignedIntValue]; }
        @catch (id e) {}
        if (vdid != 0) {
            /* Retain ALL of these for the display's lifetime — CGVirtualDisplay and
             * its listener thread reference the descriptor (and its queue), the mode,
             * and the settings after this function returns. Letting them dealloc here
             * was a use-after-free that crashed the daemon mid-session. */
            _vdObject     = vd;
            _vdDescriptor = desc;
            _vdMode       = mode;
            _vdSettings   = settings;
            _did = vdid;
            rdp_info("virtual display created: displayID=%u %ux%u (applied=%d)",
                     _did, _w, _h, applied);

            /* Make the virtual display the MAIN display so the menu bar, Dock, and
             * newly-opened windows land ON it. Otherwise apps open on the built-in
             * screen, invisible to the RDP session ("windows never pop up"). Give the
             * new display a moment to register, then put it at the global origin
             * (0,0) = main, and move the former main (built-in) to its right. */
            usleep(400000);
            if (_hidpi) select_hidpi_mode(_did, _w, _h);
            if (CGMainDisplayID() != _did)
                _layoutGen = apply_session_layout(_did, _w, _h, _hidpi);
        } else {
            rdp_error("virtual display has no displayID — main display");
        }
    } @catch (NSException *e) {
        rdp_error("virtual display creation threw (%s) — main display",
                  e.reason.UTF8String ?: "?");
        _did = CGMainDisplayID();
    }
}
#endif

@end
