// OPCrashTrap.h — guest-only fatal-error recorders (installed once per process).
//
// Two recorders, both fail-open and best-effort:
//  - ObjC uncaught exceptions (chained: prior handler still runs).
//  - Fatal signals ABRT/SEGV/BUS/ILL/TRAP/FPE (async-signal-safe only; re-raise after).
// Never SIGKILL/SIGSTOP (uncatchable). Never returns from a fault handler.
// Under a tracer (lldb) the kernel routes faults to the debugger; these don't fire.

#ifndef OPCrashTrap_h
#define OPCrashTrap_h

#include <stdbool.h>

/// Install both recorders. Copies all strings (safe context required: call from the
/// main-async engine start, never from a dyld constructor). Safe to call once.
void OPCrashTrapInstall(const char *logDir, const char *runId,
                        const char *bundleID, bool agentMode);

/// Stash the in-flight hook name for the next record (phase-4 hook guards call this;
/// plain strncpy, async-signal-safe to read later).
void OPCrashTrapNoteHook(const char *hook);

#endif
