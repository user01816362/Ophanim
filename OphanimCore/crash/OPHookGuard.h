// OPHookGuard.h — run-hook-body protection for Swift callers.
//
// Swift cannot catch ObjC exceptions ("no safe way to recover from Objective-C
// exceptions in Swift" - Apple). Every hook body that touches app objects (arg
// rendering, KVC, description) therefore runs through these wrappers: on throw they
// capture name/reason and report NO, and the caller fails open (calls the original,
// disables the hook, logs an event) instead of propagating the exception into the app.

#ifndef OPHookGuard_h
#define OPHookGuard_h

#import <Foundation/Foundation.h>

/// Run body; YES when it completed, NO when it threw (name/reason copied out, NULL-ok).
/// Synchronous: safe to read out-params on return.
BOOL OPHookGuardRun(void (^body)(void),
                    NSString * _Nullable * _Nullable outName,
                    NSString * _Nullable * _Nullable outReason);

/// Value-returning variant for pump-style dispatch: the body result, or nil when it threw
/// (name/reason out as above). The caller substitutes its own failure value.
id _Nullable OPHookGuardProtect(id _Nullable (^body)(void),
                                NSString * _Nullable * _Nullable outName,
                                NSString * _Nullable * _Nullable outReason);

#endif
