//
//  InspectorWeb.m
//  Galgal
//
//  See InspectorWeb.h. evaluateJavaScript runs in the page's main world
//  (legacy completionHandler API — old-SDK safe); the snapshot serializer is
//  frozen (no operator JS ever executes — only the fixed strings below).
//  WebKit itself is never linked: the class is resolved at runtime via
//  NSClassFromString, and the one method we need is declared on the
//  OPWebPageEvaluator protocol below (informal conformance — no WebKit
//  headers, so unlinked apps simply report "no webview").

#import "InspectorWeb.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>

static const double OPWebTimeout = 12.0;

/// The single WebKit entry point we use, declared locally so this file
/// compiles without linking or importing WebKit. Signature matches
/// WKWebView's legacy main-world eval (completion delivers on the main
/// queue — the runloop spin below is what lets it land).
@protocol OPWebPageEvaluator <NSObject>
- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^)(id _Nullable result, NSError * _Nullable error))completionHandler;
@end

// Frozen DOM serializer. Password values always masked (not redaction-gated:
// page text may hold secrets the operator never asked to see).
static NSString * const kSnapshotJS =
@"(function(){"
@"var out=[],n=0;"
@"function cssPath(el){var parts=[],d=0;"
@"while(el&&el.nodeType===1&&el!==document.body&&d<12){"
@"var tag=el.tagName.toLowerCase(),idx=1,sib=el;"
@"while((sib=sib.previousElementSibling)!=null){if(sib.tagName===el.tagName)idx++;}"
// cssPath() counts same-TAG siblings, so it must emit :nth-of-type (same-tag
// index), not :nth-child (all-sibling index): the two disagree whenever tags
// interleave, and the recorded path then matches nothing on replay.
@"parts.unshift(tag+(idx>1?':nth-of-type('+idx+')':''));"
@"el=el.parentElement;d++;}"
@"parts.unshift('body');return parts.join(' > ');}"
@"var els=document.querySelectorAll('input,textarea,select,button,a,[role=\"button\"],h1,h2,h3');"
@"for(var k=0;k<els.length&&n<300;k++){"
@"var el=els[k],r=el.getBoundingClientRect(),t=el.tagName.toLowerCase();"
@"var o={ref:n++,tag:t,type:el.type||null,"
@"text:(el.innerText||'').slice(0,120),"
@"placeholder:el.placeholder||null,href:el.href||null,"
@"frame:[Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)],"
@"path:cssPath(el)};"
@"if(t==='input'&&(el.type==='password'||el.autocomplete==='current-password')){o.value='•••';o.secret=true;}"
@"else if('value' in el&&typeof el.value==='string'){o.value=String(el.value).slice(0,200);}"
@"out.push(o);}"
@"return JSON.stringify({url:location.href,title:document.title,count:out.length,nodes:out});"
@"})()";

/// Key window, same contract as Inspector.keyWindow (Swift): visible-scene
/// windows, key first, then first visible. One funnel so DOM eval and the
/// tree/tap paths never disagree about which window they mean.
static UIWindow *OPKeyWindow(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.isHidden && w.alpha > 0.01) { [windows addObject:w]; }
        }
    }
    for (UIWindow *w in windows) { if (w.isKeyWindow) { return w; } }
    return windows.firstObject;
}

/// First WKWebView under the key window (depth-first). Nil class (app never
/// loaded WebKit) or no webview on screen both mean nil: stated upstream.
/// Eval capability is checked with respondsToSelector, not conformsToProtocol:
/// a genuine WKWebView never adopts our local protocol (informal conformance
/// only — that check would reject every real webview).
static UIView<OPWebPageEvaluator> *OPFirstWebView(void) {
    Class WKWebViewClass = NSClassFromString(@"WKWebView");
    if (!WKWebViewClass) { return nil; }
    UIWindow *window = OPKeyWindow();
    if (!window) { return nil; }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:WKWebViewClass] &&
            [v respondsToSelector:@selector(evaluateJavaScript:completionHandler:)]) {
            return (UIView<OPWebPageEvaluator> *)v;
        }
        NSArray<UIView *> *subs = nil;
        @try { subs = [v.subviews copy]; } @catch (__unused NSException *e) { continue; }
        for (UIView *s in subs.reverseObjectEnumerator) { [stack addObject:s]; }
    }
    return nil;
}

// Run a script string on a webview with a bounded runloop spin (main-thread
// pump safe: completions deliver on turns instead of deadlocking a semaphore).
static NSString *OPRunJS(UIView<OPWebPageEvaluator> *webView, NSString *script) {
    if (!webView || !script) { return nil; }
    __block NSString *result = nil;
    __block BOOL done = NO;
    @try {
        [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
            if (!error && value) {
                if ([value isKindOfClass:[NSString class]]) { result = value; }
                else { result = [NSString stringWithFormat:@"%@", value]; }
            }
            done = YES;
        }];
    } @catch (__unused NSException *e) { return nil; }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:OPWebTimeout];
    while (!done && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return done ? result : nil;
}

static char *OPDup(NSString *s) {
    if (!s) { return NULL; }
    const char *utf8 = [s UTF8String];
    if (!utf8) { return NULL; }
    size_t n = strlen(utf8) + 1;
    char *out = malloc(n);
    if (out) { memcpy(out, utf8, n); }
    return out;
}

const char *OPWebSnapshot(void) {
    UIView<OPWebPageEvaluator> *webView = OPFirstWebView();
    if (!webView) { return NULL; }
    return OPDup(OPRunJS(webView, kSnapshotJS));
}

/// Precise reason the last lookup failed (malloc'd; caller frees with
/// OPWebFree). Lets the operator distinguish "web not on screen" from
/// "lookup itself broken" without a debugger.
const char *OPWebDiagnose(void) {
    if (!NSClassFromString(@"WKWebView")) { return OPDup(@"webkit-not-loaded"); }
    if (!OPKeyWindow()) { return OPDup(@"no-key-window"); }
    return OPDup(@"no-webview-under-key-window");
}

// JSON-encode a value string into a JS string literal (quoting safe by
// construction — embedding raw operator text would be an injection hole).
static NSString *OPJSLiteral(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0 error:NULL];
    if (!data) { return @"\"\""; }
    NSString *arr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (arr.length < 2) { return @"\"\""; }
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

const char *OPWebAct(const char *cssPath, const char *action, const char *value) {
    if (!cssPath || !action) { return NULL; }
    UIView<OPWebPageEvaluator> *webView = OPFirstWebView();
    if (!webView) { return NULL; }
    NSString *path = [NSString stringWithUTF8String:cssPath];
    NSString *act = [NSString stringWithUTF8String:action];
    NSString *val = value ? OPJSLiteral([NSString stringWithUTF8String:value]) : @"\"\"";
    // Single-quoted path: cssPath() emits tag/nth-of-type chains only (no quotes possible).
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        @"var el=document.querySelector('%@');"
        @"if(!el) return 'missing';"
        @"var act='%@';"
        @"if(act==='click'){el.click();return 'clicked';}"
        @"if(act==='fill'){el.focus();el.value=%@;"
        @"el.dispatchEvent(new Event('input',{bubbles:true}));"
        @"el.dispatchEvent(new Event('change',{bubbles:true}));return 'filled';}"
        @"if(act==='select'){el.value=%@;"
        @"el.dispatchEvent(new Event('change',{bubbles:true}));return 'selected';}"
        @"if(act==='submit'){var f=el.closest('form');"
        @"if(f){f.submit();return 'submitted';}el.click();return 'clicked';}"
        @"return 'unknown-action';})()",
        path, act, val, val];
    return OPDup(OPRunJS(webView, script));
}

void OPWebFree(const char *s) {
    if (s) { free((void *)s); }
}
