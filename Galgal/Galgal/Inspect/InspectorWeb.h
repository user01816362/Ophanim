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

/// Act on a snapshot node: fingerprint re-resolution first (exact match +
/// uniqueness gate over a live re-walk), recorded CSS path last resort
/// (marked via:path). `fingerprint`/`cssPath`/`snapshotUrl` accept "" for
/// absent (NULL-tolerant); at least one locator is required. `action` is
/// fill (native-setter + input/change events, text-like inputs + textarea;
/// secrets need consent!=0) | click | select | submit. `value` is
/// JSON-encoded into the script (no injection). Returns malloc'd result
/// string (filled@tag/clicked@tag/ref-miss/ambiguous:N/navigated:…/…),
/// or NULL on failure. The filled value is never echoed back.
const char *OPWebAct(int ref, const char *fingerprint, const char *cssPath,
                      const char *action, const char *value,
                      const char *snapshotUrl, int consent);

/// Precise reason the last webview lookup failed (malloc'd; free with OPWebFree):
/// "webkit-not-loaded" | "no-key-window" | "no-webview-under-key-window".
const char *OPWebDiagnose(void);

/// Frees strings returned above.
void OPWebFree(const char *s);
