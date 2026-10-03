//
//  InspectorWeb.m
//  Galgal
//
//  Web-content bridge for agent operation (no new deps, no WebKit linkage):
//  WKWebView is resolved at runtime via NSClassFromString, so this file
//  compiles and loads even in apps that never link WebKit (those simply
//  report "no webview"). All entry points block the caller with a bounded
//  runloop spin (main-thread pump safe — mirrors the swipe phase spins).
//
//  Reference model (Playwright-convergent, cross-app — not per-page): snapshot
//  emits semantic fingerprints; act re-resolves the fingerprint against the
//  LIVE DOM with a uniqueness gate, URL-bound and fail-closed. Recorded CSS
//  paths are the last-resort locator only (marked via:path). No DOM node is
//  ever held across calls; no operator JS ever executes (frozen strings only;
//  OPJSLiteral is the sole value entry point).

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
// page text may hold secrets the operator never asked to see). Legacy JS
// syntax only (no ?. / ?? / arrows / template literals — old-WebKit parse
// safety). The fp/nodeLabel/secretOf/cssPath helpers below are duplicated
// verbatim in the act script: the two evals share no globals, so each must
// be self-contained, and the duplication keeps the fingerprint rule identical
// on both sides by construction (keep them in sync on edit).
static NSString * const kSnapshotJS =
@"(function(){"
@"function nodeLabel(el){"
@"var a=el.getAttribute&&el.getAttribute('aria-label');"
@"if(a) return a.slice(0,120);"
@"if(el.labels&&el.labels.length){var t=el.labels[0].innerText||'';if(t) return t.slice(0,120);}"
@"var by=el.getAttribute&&el.getAttribute('aria-labelledby');"
@"if(by){var ids=by.split(/\\s+/),parts=[];"
@"for(var i=0;i<ids.length&&i<4;i++){var n=document.getElementById(ids[i]);"
@"if(n&&n.innerText) parts.push(n.innerText);}"
@"if(parts.length) return parts.join(' ').slice(0,120);}"
@"var p=el.parentElement,d=0;"
@"while(p&&d<4){if(p.tagName&&p.tagName.toLowerCase()==='label'){"
@"var lt=p.innerText||'';if(lt) return lt.slice(0,120);}"
@"p=p.parentElement;d++;}"
@"return null;}"
@"function secretOf(el,tag){"
@"var tp=((el.type||'').toLowerCase());"
@"var ac='';if(el.getAttribute){ac=(el.getAttribute('autocomplete')||'').toLowerCase();}"
@"if(tag==='input'&&(tp==='password'||ac==='current-password'||ac==='new-password'||"
@"ac==='cc-number'||ac==='cc-exp'||ac==='cc-csc')) return 'secret';"
@"if(tag==='input'&&tp==='hidden') return 'hidden';"
@"if(tag==='input'&&tp==='file') return 'file';"
@"return '';}"
@"function fpFor(el){"
@"var t=el.tagName.toLowerCase();"
@"var lb=nodeLabel(el)||'';"
@"return t+'|'+(el.type||'')+'|'+(el.id||'')+'|'+(el.name||'')+'|'+"
@"(el.placeholder||'')+'|'+lb+'|'+((el.innerText||'').slice(0,120))+'|'+(el.href||'');}"
@"function cssPath(el){var parts=[];"
@"while(el&&el.nodeType===1&&el!==document.body){"
@"var tag=el.tagName.toLowerCase(),idx=1,sib=el;"
@"while((sib=sib.previousElementSibling)!=null){if(sib.tagName===el.tagName)idx++;}"
@"parts.unshift(tag+(idx>1?':nth-of-type('+idx+')':''));"
@"el=el.parentElement;}"
@"parts.unshift('body');return parts.join(' > ');}"
@"var out=[],n=0;"
@"var els=document.querySelectorAll('input,textarea,select,button,a,[role=\"button\"],h1,h2,h3');"
@"for(var k=0;k<els.length&&n<300;k++){"
@"var el=els[k],r=el.getBoundingClientRect(),t=el.tagName.toLowerCase();"
@"var o={ref:n++,tag:t,type:el.type||null,"
@"text:(el.innerText||'').slice(0,120),"
@"placeholder:el.placeholder||null,href:el.href||null,"
@"id:((el.id||'').slice(0,80))||null,name:((el.name||'').slice(0,80))||null,"
@"autocomplete:(el.getAttribute&&el.getAttribute('autocomplete'))||null,"
@"label:nodeLabel(el),"
@"frame:[Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)],"
@"path:cssPath(el)};"
@"o.fp=fpFor(el);"
@"var sk=secretOf(el,t);"
@"if(sk==='secret'){o.value='•••';o.secret=true;}"
@"else if(sk==='hidden'){o.secret=true;}"
@"else if(sk==='file'){}"
@"else if('value' in el&&typeof el.value==='string'){o.value=String(el.value).slice(0,200);}"
@"if(t.indexOf('-')>=0&&el.shadowRoot&&el.shadowRoot.children&&el.shadowRoot.children.length>0){o.shadowHost=true;}"
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

const char *OPWebAct(int ref, const char *fingerprint, const char *cssPath,
                      const char *action, const char *value,
                      const char *snapshotUrl, int consent) {
    if (!action) { return NULL; }
    int hasFp = fingerprint && fingerprint[0] != '\0';
    int hasPath = cssPath && cssPath[0] != '\0';
    if (!hasFp && !hasPath) { return NULL; }
    UIView<OPWebPageEvaluator> *webView = OPFirstWebView();
    if (!webView) { return NULL; }
    NSString *fp = hasFp ? OPJSLiteral([NSString stringWithUTF8String:fingerprint]) : @"\"\"";
    NSString *path = hasPath ? OPJSLiteral([NSString stringWithUTF8String:cssPath]) : @"\"\"";
    NSString *act = [NSString stringWithUTF8String:action];
    NSString *val = value ? OPJSLiteral([NSString stringWithUTF8String:value]) : @"\"\"";
    NSString *snapURL = (snapshotUrl && snapshotUrl[0] != '\0')
        ? OPJSLiteral([NSString stringWithUTF8String:snapshotUrl]) : @"\"\"";
    // ref is the host's cache key (stale-ref pre-bail lives host-side); the
    // guest resolves by fingerprint equality with a mandatory full-scan
    // uniqueness gate, so ref needs no guest-side indexing (the scan subsumes
    // any fast path and keeps strictness honest). Unused by design — documented
    // so a future reader doesn't "fix" it back in.
    (void)ref;
    // Fingerprint, path, URL, and value all travel JSON-encoded via OPJSLiteral
    // (quoting safe by construction — embedding raw operator text previously
    // broke script syntax on quotes). The path emits tag/nth-of-type chains.
    // Positional steps resolve MANUALLY (same-tag child index — the exact rule
    // the serializer counts by) instead of trusting the engine's :nth-of-type
    // under :scope, which returned null live for a present 2nd div. The step
    // regex admits h1-h6 and custom elements (bare [a-z]+ silently dropped
    // their index — a certain latent bug in the prior version).
    // Fill targets are asserted (text-like input/textarea with a value prop)
    // so a divergent resolution can never write into the wrong node.
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        @"if(%@&&%@!==''&&location.href!==%@) return 'navigated:'+location.href;"
        @"function nodeLabel(el){"
        @"var a=el.getAttribute&&el.getAttribute('aria-label');"
        @"if(a) return a.slice(0,120);"
        @"if(el.labels&&el.labels.length){var t=el.labels[0].innerText||'';if(t) return t.slice(0,120);}"
        @"var by=el.getAttribute&&el.getAttribute('aria-labelledby');"
        @"if(by){var ids=by.split(/\\s+/),parts=[];"
        @"for(var i=0;i<ids.length&&i<4;i++){var n=document.getElementById(ids[i]);"
        @"if(n&&n.innerText) parts.push(n.innerText);}"
        @"if(parts.length) return parts.join(' ').slice(0,120);}"
        @"var p=el.parentElement,d=0;"
        @"while(p&&d<4){if(p.tagName&&p.tagName.toLowerCase()==='label'){"
        @"var lt=p.innerText||'';if(lt) return lt.slice(0,120);}"
        @"p=p.parentElement;d++;}"
        @"return null;}"
        @"function fpFor(el){"
        @"var t=el.tagName.toLowerCase();"
        @"var lb=nodeLabel(el)||'';"
        @"return t+'|'+(el.type||'')+'|'+(el.id||'')+'|'+(el.name||'')+'|'+"
        @"(el.placeholder||'')+'|'+lb+'|'+((el.innerText||'').slice(0,120))+'|'+(el.href||'');}"
        @"function stepResolve(root,step){"
        @"var m=/^([a-z][a-z0-9-]*)(?::nth-of-type\\((\\d+)\\))?$/.exec(step);"
        @"if(!m) return root.querySelector(':scope > '+step);"
        @"var want=parseInt(m[2]||'1',10),seen=0,kids=root.children;"
        @"for(var k=0;k<kids.length;k++){"
        @"if(kids[k].tagName.toLowerCase()===m[1]){seen++;if(seen===want) return kids[k];}}"
        @"return null;}"
        @"var FP=%@,el=null,via='';"
        @"if(FP&&FP!==''){"
        @"var els=document.querySelectorAll('input,textarea,select,button,a,[role=\"button\"],h1,h2,h3');"
        @"var hits=[];"
        @"for(var k=0;k<els.length;k++){if(fpFor(els[k])===FP) hits.push(els[k]);}"
        @"if(hits.length===0) return 'ref-miss';"
        @"if(hits.length>1) return 'ambiguous:'+hits.length;"
        @"el=hits[0];}"
        @"else{"
        @"var steps=%@.split(' > ');"
        @"el=document;"
        @"for(var s=0;s<steps.length;s++){"
        @"var next=(s===0)?document.querySelector(steps[0]):stepResolve(el,steps[s]);"
        @"if(!next){var info='';try{"
        @"var ck=el.children,dc=0;"
        @"for(var j=0;j<ck.length;j++){if(ck[j].tagName.toLowerCase()==='div')dc++;}"
        @"info='|parent='+el.tagName.toLowerCase()+'#kids='+ck.length+'#divs='+dc;"
        @"}catch(e){}"
        @"return 'missing@'+s+'/'+steps.length+info;}"
        @"el=next;}"
        @"via='+via:path';}"
        @"var tag=el.tagName.toLowerCase(),op='%@',allow=%d;"
        @"if(op==='fill'){"
        @"var tp=((el.type||'').toLowerCase());"
        @"var ac='';if(el.getAttribute){ac=(el.getAttribute('autocomplete')||'').toLowerCase();}"
        @"var sec=(tag==='input'&&(tp==='password'||ac==='current-password'||ac==='new-password'||"
        @"ac==='cc-number'||ac==='cc-exp'||ac==='cc-csc')); "
        @"if(sec&&!allow) return 'secret-needs-consent';"
        @"if(tag==='input'&&tp==='hidden') return 'not-fillable:hidden';"
        @"if(tag==='input'&&tp==='file') return 'no-file-upload';"
        @"if(tag==='input'&&(tp==='checkbox'||tp==='radio')) return 'use-click:'+tp;"
        @"var textlike=(tag==='textarea')||(tag==='input'&&("
        @"tp==='text'||tp==='password'||tp==='email'||tp==='search'||tp==='tel'||tp==='url'||tp==='number')); "
        @"if(!textlike||!('value' in el)) return 'not-fillable:'+tag;"
        @"el.focus();"
        @"var proto=(tag==='textarea')?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;"
        @"var desc=Object.getOwnPropertyDescriptor(proto,'value');"
        @"if(desc&&desc.set) desc.set.call(el,%@); else el.value=%@;"
        @"el.dispatchEvent(new Event('input',{bubbles:true}));"
        @"el.dispatchEvent(new Event('change',{bubbles:true}));"
        @"return 'filled@'+tag+via;}"
        @"if(op==='click'){el.click();return 'clicked@'+tag+via;}"
        @"if(op==='select'){"
        @"if(!('value' in el)) return 'not-selectable:'+tag;"
        @"el.value=%@;"
        @"el.dispatchEvent(new Event('change',{bubbles:true}));"
        @"return 'selected@'+tag+via;}"
        @"if(op==='submit'){var f=el.closest('form');"
        @"if(f){f.submit();return 'submitted';}el.click();return 'clicked@'+tag+via;}"
        @"return 'unknown-action';})()",
        snapURL, snapURL, snapURL, fp, path, act, consent, val, val, val];
    return OPDup(OPRunJS(webView, script));
}

void OPWebFree(const char *s) {
    if (s) { free((void *)s); }
}
