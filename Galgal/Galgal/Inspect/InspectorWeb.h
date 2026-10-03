//
//  InspectorWeb.h
//  Galgal
//
//  Web-content bridge for agent operation (no new deps, no WebKit linkage):
//  WKWebView is resolved at runtime via NSClassFromString, so this file
//  compiles and loads even in apps that never link WebKit (those simply
//  report "no webview"). All entry points block the caller with a bounded
//  runloop spin (main-thread pump safe — mirrors the swipe phase spins).

#import <Foundation/Foundation.h>

/// Frozen DOM snapshot JSON: {url, title, count, nodes:[{ref,tag,type,text,
/// value(masked for passwords),placeholder,href,frame,path}]}. Cap 300 nodes.
/// Returns malloc'd UTF-8 (caller frees), or NULL when no webview / timeout.
const char *OPWebSnapshot(void);

/// Act on a snapshot node by CSS path: "fill" (value + input/change events, so
/// React-controlled inputs accept it), "click", "select", "submit".
/// `value` is JSON-encoded into the script (no injection). Returns malloc'd
/// result string ("filled"/"clicked"/"missing"/...), or NULL on failure.
/// The filled value is never echoed back.
const char *OPWebAct(const char *cssPath, const char *action, const char *value);

/// Frees strings returned above.
void OPWebFree(const char *s);
