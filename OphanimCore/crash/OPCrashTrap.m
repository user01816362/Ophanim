// OPCrashTrap.m — guest-only fatal-error recorders. See header for the contract.
//
// Async-signal-safety discipline (POSIX list): the signal handler uses backtrace(),
// write(2), and plain memory reads ONLY. No malloc/free, stdio, NSLog, ObjC/Swift,
// locks, dladdr, or backtrace_symbols. Symbolication happens at read time in the host,
// which owns the same image set. The exception handler is NOT signal context (ObjC
// runtime works; LiveContainer precedent writes strings there too).

#import "OPCrashTrap.h"
#import <Foundation/Foundation.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

#define OP_CRASH_MAXFRAMES 32

static char *g_logDir = NULL;
static char *g_runId = NULL;
static char *g_bundleID = NULL;
static bool g_agentMode = false;
static NSUncaughtExceptionHandler *g_priorHandler = NULL;
static int g_rawFd = -1;
static char g_lastHook[256] = {0};
static void *g_frames[OP_CRASH_MAXFRAMES];

void OPCrashTrapNoteHook(const char *hook) {
    if (!hook) { g_lastHook[0] = '\0'; return; }
    strncpy(g_lastHook, hook, sizeof(g_lastHook) - 1);
    g_lastHook[sizeof(g_lastHook) - 1] = '\0';
}

static void OPCrashTrapRecordPath(char *out, size_t len, const char *suffix) {
    snprintf(out, len, "%s/run-%s.%s", g_logDir ? g_logDir : "",
             g_runId ? g_runId : "unknown", suffix);
}

// --- signal path (async-signal-safe subset only) ---

static void OPCrashTrapWriteHex(int fd, unsigned long long v) {
    // No snprintf (not async-signal-safe): hand-rolled hex, no padding.
    char buf[16];
    int n = 0;
    if (v == 0) { buf[n++] = '0'; }
    else {
        char rev[16]; int m = 0;
        while (v && m < 16) { int d = v & 0xF; rev[m++] = d < 10 ? '0' + d : 'a' + d - 10; v >>= 4; }
        while (m--) { buf[n++] = rev[m]; }
    }
    (void)write(fd, "0x", 2);
    (void)write(fd, buf, (size_t)n);
}

static void OPCrashTrapWriteStr(int fd, const char *s) {
    if (s) { (void)write(fd, s, strlen(s)); }
}

static void OPCrashTrapSignalHandler(int signo, siginfo_t *info, void *ctx) {
    (void)info; (void)ctx;
    if (g_rawFd >= 0) {
        OPCrashTrapWriteStr(g_rawFd, "OPCRASH signal=");
        OPCrashTrapWriteHex(g_rawFd, (unsigned long long)signo);
        OPCrashTrapWriteStr(g_rawFd, " run=");
        OPCrashTrapWriteStr(g_rawFd, g_runId);
        OPCrashTrapWriteStr(g_rawFd, " hook=");
        OPCrashTrapWriteStr(g_rawFd, g_lastHook[0] ? g_lastHook : "-");
        OPCrashTrapWriteStr(g_rawFd, "\n");
        int n = backtrace(g_frames, OP_CRASH_MAXFRAMES);
        for (int i = 0; i < n; i++) {
            OPCrashTrapWriteStr(g_rawFd, "ADDR ");
            OPCrashTrapWriteHex(g_rawFd, (unsigned long long)g_frames[i]);
            OPCrashTrapWriteStr(g_rawFd, "\n");
        }
        OPCrashTrapWriteStr(g_rawFd, "END\n");
        // Do NOT close: keep it simple, the process is dying; re-raise below.
    }
    // Restore default and re-raise so the OS still produces its own report and the
    // process actually terminates (returning would re-execute the faulting instruction).
    signal(signo, SIG_DFL);
    raise(signo);
    _exit(128 + signo); // only if re-raise somehow returns
}

// --- exception path (ObjC runtime works here) ---

static void OPCrashTrapExceptionHandler(NSException *exc) {
    @try {
        NSArray *stack = [exc callStackSymbols];
        if ([stack count] > 16) { stack = [stack subarrayWithRange:NSMakeRange(0, 16)]; }
        NSDictionary *record = @{
            @"version": @1,
            @"runId": g_runId ? [NSString stringWithUTF8String:g_runId] : @"",
            @"bundleID": g_bundleID ? [NSString stringWithUTF8String:g_bundleID] : @"",
            @"pid": @(getpid()),
            @"kind": @"objc-exception",
            @"exceptionName": [exc name] ?: @"?",
            @"exceptionReason": [exc reason] ?: @"",
            @"lastHook": g_lastHook[0] ? [NSString stringWithUTF8String:g_lastHook] : @"",
            @"frames": stack ?: @[],
            @"agentMode": @(g_agentMode),
        };
        char path[1024];
        OPCrashTrapRecordPath(path, sizeof(path), "crashreason.json");
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
        if (data) { [data writeToFile:[NSString stringWithUTF8String:path] atomically:YES]; }
    } @catch (...) {
        // A crashing crash-reporter helps no one; fall through to the prior handler.
    }
    if (g_priorHandler) { g_priorHandler(exc); }
    else { abort(); } // default behavior: log-then-exit lives in the default handler
}

void OPCrashTrapInstall(const char *logDir, const char *runId,
                        const char *bundleID, bool agentMode) {
    static BOOL installed = NO;
    if (installed) { return; }
    installed = YES;
    g_logDir = logDir ? strdup(logDir) : NULL;
    g_runId = runId ? strdup(runId) : NULL;
    g_bundleID = bundleID ? strdup(bundleID) : NULL;
    g_agentMode = agentMode;
    // Pre-open the signal record OUTSIDE any handler (open is not async-signal-safe).
    char rawPath[1024];
    OPCrashTrapRecordPath(rawPath, sizeof(rawPath), "signalraw");
    g_rawFd = open(rawPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    // Chain, never replace: a prior handler (debugger shims, SDKs) still runs.
    g_priorHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&OPCrashTrapExceptionHandler);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = &OPCrashTrapSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    int fatals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof(fatals) / sizeof(fatals[0]); i++) {
        sigaction(fatals[i], &sa, NULL);
    }
}
