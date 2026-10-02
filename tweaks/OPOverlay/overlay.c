// OPOverlay — example user tweak: floating mod-menu panel injected through the
// Ophanim tweak store (add_tweak + resync_tweaks + relaunch). Pure C against the
// ObjC runtime: no UIKit import, no new build deps — every class is resolved with
// objc_getClass and every call goes through objc_msgSend, so this compiles with
// the command-line tools alone:
//
//   cc -arch arm64 -target arm64-apple-ios16.0-macabi -dynamiclib overlay.c \
//      -framework Foundation -o OPOverlay.dylib
//
// The host syncs it into Frameworks/UserPlugins, signs it, and the Galgal runtime
// dlopens it at startup (OPLoadUserTweaks). Remove with remove_tweak + resync.

#import <objc/runtime.h>
#import <objc/message.h>   // objc_msgSend (not re-exported by runtime.h on newer SDKs)
#import <dispatch/dispatch.h>
#import <stdio.h>      // snprintf (bundle line)

typedef struct { double x, y; } OPPoint;

// ---- tiny msgSend vocabulary (arm64: object/scalar/≤16-byte-struct traffic only;
// no CGRect-returning calls — CGRect is 32 bytes and needs the stret variant).
static id OP_send(id o, const char *sel) {
    return ((id(*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}
static id OP_send1(id o, const char *sel, id a) {
    return ((id(*)(id, SEL, id))objc_msgSend)(o, sel_registerName(sel), a);
}
static id OP_sendL(id o, const char *sel, long v) {
    return ((id(*)(id, SEL, long))objc_msgSend)(o, sel_registerName(sel), v);
}
static void OP_sendB(id o, const char *sel, _Bool b) {
    ((void(*)(id, SEL, _Bool))objc_msgSend)(o, sel_registerName(sel), b);
}
static void OP_sendD(id o, const char *sel, double d) {
    ((void(*)(id, SEL, double))objc_msgSend)(o, sel_registerName(sel), d);
}
static void OP_sendDD(id o, const char *sel, double a, double b) {
    ((void(*)(id, SEL, double, double))objc_msgSend)(o, sel_registerName(sel), a, b);
}
static id OP_sendDDr(id o, const char *sel, double a, double b) {
    return ((id(*)(id, SEL, double, double))objc_msgSend)(o, sel_registerName(sel), a, b);
}
static OPPoint OP_sendPoint(id o, const char *sel) {
    return ((OPPoint(*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}
static OPPoint OP_sendPoint1(id o, const char *sel, id a) {
    return ((OPPoint(*)(id, SEL, id))objc_msgSend)(o, sel_registerName(sel), a);
}
static void OP_sendSetPoint(id o, const char *sel, OPPoint p) {
    ((void(*)(id, SEL, OPPoint))objc_msgSend)(o, sel_registerName(sel), p);
}
static long OP_sendLong(id o, const char *sel) {
    return ((long(*)(id, SEL))objc_msgSend)(o, sel_registerName(sel));
}

// NSString without linking Foundation: +stringWithUTF8String: is pure runtime.
static id OP_str(const char *c) {
    return OP_send1((id)objc_getClass("NSString"), "stringWithUTF8String:", (id)c);
}

static id g_panel = 0;
static OPPoint g_dragBase = {0, 0};

// Close action (UIButton target): drop the panel, forget it.
static void op_close(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    if (g_panel) { OP_send(g_panel, "removeFromSuperview"); g_panel = 0; }
}

// Pan handler: began snapshots the center, changed re-applies center = base + drag.
static void op_drag(id self, SEL cmd, id gesture) {
    (void)self; (void)cmd;
    if (!g_panel) { return; }
    long state = OP_sendLong(gesture, "state");
    if (state == 1) {           // UIGestureRecognizerStateBegan
        g_dragBase = OP_sendPoint(g_panel, "center");
    } else if (state == 2) {    // Changed
        id super = OP_send(g_panel, "superview");
        if (!super) { return; }
        OPPoint t = OP_sendPoint1(gesture, "translationInView:", super);
        OP_sendSetPoint(g_panel, "setCenter:",
                        (OPPoint){g_dragBase.x + t.x, g_dragBase.y + t.y});
    }
}

static id OP_label(const char *text, double size, id color,
                   double x, double y, double w, double h, long align) {
    id cls = (id)objc_getClass("UILabel");
    id v = OP_send(cls, "alloc");
    struct { double x, y, w, h; } frame = {x, y, w, h};
    v = ((id(*)(id, SEL, typeof(frame)))objc_msgSend)(v, sel_registerName("initWithFrame:"), frame);
    OP_send1(v, "setText:", OP_str(text));
    OP_send1(v, "setTextColor:", color);
    OP_send1(v, "setBackgroundColor:",
             OP_send((id)objc_getClass("UIColor"), "clearColor"));
    (void)align;
    return v;
}

static void op_show(void) {
    id app = OP_send((id)objc_getClass("UIApplication"), "sharedApplication");
    if (!app) { return; }
    id window = OP_send(app, "keyWindow");
    if (!window) { return; }

    id panel = OP_send((id)objc_getClass("UIView"), "alloc");
    struct { double x, y, w, h; } frame = {16, 64, 250, 132};
    panel = ((id(*)(id, SEL, typeof(frame)))objc_msgSend)(
        panel, sel_registerName("initWithFrame:"), frame);
    id dark = OP_sendDDr((id)objc_getClass("UIColor"), "colorWithWhite:alpha:", 0.08, 0.94);
    OP_send1(panel, "setBackgroundColor:", dark);
    id layer = OP_send1(panel, "valueForKey:", OP_str("layer"));
    OP_sendD(layer, "setCornerRadius:", 12.0);
    OP_sendB(layer, "setMasksToBounds:", 1);

    id white = OP_send((id)objc_getClass("UIColor"), "whiteColor");
    id red = OP_send((id)objc_getClass("UIColor"), "redColor");
    id title = OP_label("OPHANIM", 15, white, 12, 8, 226, 20, 1);
    id sub = OP_label("tweak loaded: drag me / X closes", 11, red, 12, 30, 226, 16, 1);
    id bid = OP_label("bundle: ?", 11, white, 12, 48, 226, 16, 1);
    {
        id mainBundle = OP_send((id)objc_getClass("NSBundle"), "mainBundle");
        id bidStr = mainBundle ? OP_send(mainBundle, "bundleIdentifier") : 0;
        const char *c = bidStr ? (const char *)((const char *(*)(id, SEL))objc_msgSend)(
            bidStr, sel_registerName("UTF8String")) : "?";
        char buf[160];
        snprintf(buf, sizeof(buf), "bundle: %.120s", c ? c : "?");
        OP_send1(sub, "setText:", OP_str("tweak loaded: drag to move"));
        OP_send1(bid, "setText:", OP_str(buf));
    }
    OP_send1(panel, "addSubview:", title);
    OP_send1(panel, "addSubview:", sub);
    OP_send1(panel, "addSubview:", bid);

    // Close (X) + drag target: one tiny runtime class, two methods.
    Class cls = objc_allocateClassPair((Class)objc_getClass("NSObject"), "OPOverlayDelegate", 0);
    class_addMethod(cls, sel_registerName("closeTapped:"),
                    (IMP)op_close, "v@:@");
    class_addMethod(cls, sel_registerName("dragged:"),
                    (IMP)op_drag, "v@:@");
    objc_registerClassPair(cls);
    id delegate = OP_send((id)cls, "new");

    id close = OP_sendL((id)objc_getClass("UIButton"), "buttonWithType:", 0);
    struct { double x, y, w, h; } cframe = {214, 4, 32, 28};
    close = ((id(*)(id, SEL, typeof(cframe)))objc_msgSend)(
        close, sel_registerName("initWithFrame:"), cframe);
    {
        // setTitle:forState: is two-arg; route through a typed call.
        ((void(*)(id, SEL, id, long))objc_msgSend)(
            close, sel_registerName("setTitle:forState:"), OP_str("X"), 0);
        ((void(*)(id, SEL, id, SEL, long))objc_msgSend)(
            close, sel_registerName("addTarget:action:forControlEvents:"),
            delegate, sel_registerName("closeTapped:"), 1L << 6);
    }
    OP_send1(panel, "addSubview:", close);

    id pan = OP_send((id)objc_getClass("UIPanGestureRecognizer"), "alloc");
    pan = ((id(*)(id, SEL, id, SEL))objc_msgSend)(
        pan, sel_registerName("initWithTarget:action:"),
        delegate, sel_registerName("dragged:"));
    OP_send1(panel, "addGestureRecognizer:", pan);

    // Note: no window-level change — the panel rides in the key window's own
    // hierarchy (visible, touchable, never steals key status).
    OP_send1(window, "addSubview:", panel);
    g_panel = panel;
}

__attribute__((constructor)) static void op_overlay_init(void) {
    // Constructor context is restricted (dyld locks): defer everything.
    dispatch_async(dispatch_get_main_queue(), ^{ op_show(); });
}
