// OPHookGuard.m — see header for the contract. @try/@catch lives here so no Swift
// frame ever sits between a throw and its catcher (unwinding through Swift frames
// from ObjC exceptions is the documented-unsafe direction).

#import "OPHookGuard.h"

BOOL OPHookGuardRun(void (^body)(void),
                    NSString * _Nullable * _Nullable outName,
                    NSString * _Nullable * _Nullable outReason) {
    if (!body) { return YES; }
    @try {
        body();
        return YES;
    } @catch (NSException *exc) {
        if (outName) { *outName = [[exc name] copy]; }
        if (outReason) { *outReason = [[exc reason] copy] ?: @""; }
        return NO;
    }
}

id _Nullable OPHookGuardProtect(id _Nullable (^body)(void),
                                NSString * _Nullable * _Nullable outName,
                                NSString * _Nullable * _Nullable outReason) {
    if (!body) { return nil; }
    @try {
        return body();
    } @catch (NSException *exc) {
        if (outName) { *outName = [[exc name] copy]; }
        if (outReason) { *outReason = [[exc reason] copy] ?: @""; }
        return nil;
    }
}
