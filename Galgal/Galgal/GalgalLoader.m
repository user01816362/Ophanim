//
//  GalgalLoader.m
//  Galgal
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <sys/sysctl.h>

#import "GalgalLoader.h"
#import <Galgal/Galgal-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import "../../OphanimCore/ring/OPRing.h"   // op_ring_emit for filesystem capture

@import MachO;

// Get device model from ophanim .plist
// With a null terminator
#define DEVICE_MODEL [[[AppConfig shared] deviceModel] cStringUsingEncoding:NSUTF8StringEncoding]
#define OEM_ID [[[AppConfig shared] oemID] cStringUsingEncoding:NSUTF8StringEncoding]
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int gg_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int gg_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int gg_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int gg_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(gg_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(gg_uname, uname)
DYLD_INTERPOSE(gg_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(gg_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Extract a keychain item's service/account into a stack buffer. CoreFoundation getters don't
// allocate, so the ring producer stays allocation-free.
static void op_kc_attr(CFDictionaryRef d, char *buf, size_t cap) {
    buf[0] = '\0';
    if (!d) return;
    CFTypeRef v = CFDictionaryGetValue(d, kSecAttrService);
    if (!v) v = CFDictionaryGetValue(d, kSecAttrAccount);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, buf, (CFIndex)cap, kCFStringEncodingUTF8);
    }
}

// Shared SecItem call tail: extract service/account into a stack buffer
// (never secret bytes) and emit one ring record. One shape for all four
// wrappers so emit drift (a wrapper forgetting the account or the retval)
// is impossible by construction. Debug mirroring stays per call site
// (message shapes differ); the ring record is the contract.
static void gg_SecItemEmit(int kind, OSStatus retval, CFDictionaryRef query) {
    char acct[OP_STR_CAP]; op_kc_attr(query, acct, sizeof(acct));
    op_ring_emit(kind, 0, (int32_t)retval, acct[0] ? acct : NULL, NULL, 0);
}

// Use the implementations from KeychainShim
static OSStatus gg_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    gg_SecItemEmit(OP_K_KEYCHAIN_COPY, retval, query);
    if (result != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [KeychainShim debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus gg_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    gg_SecItemEmit(OP_K_KEYCHAIN_ADD, retval, attributes);
    if (result != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus gg_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    gg_SecItemEmit(OP_K_KEYCHAIN_UPDATE, retval, query);
    if (attributesToUpdate != NULL) {
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus gg_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    gg_SecItemEmit(OP_K_KEYCHAIN_DELETE, retval, query);
    if ([[AppConfig shared] chainGuardDebugging]) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef gg_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[AppConfig shared] chainGuard]) {
        result = [KeychainShim keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[AppConfig shared] chainGuardDebugging]) {
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus gg_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[AppConfig shared] chainGuard]) {
        retval = [KeychainShim keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[AppConfig shared] chainGuardDebugging]) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [KeychainShim debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(gg_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(gg_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(gg_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(gg_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(gg_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(gg_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int gg_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    // Allocation-free capture: op_ring_emit only memcpys into the lock-free ring, so it's safe even
    // though open() is called from inside malloc. It self-gates on the .filesystem category mask.
    op_ring_emit(OP_K_FS_OPEN, 0, oflag, filename, NULL, 0);

    if (oflag & O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, oflag, mod);
    }

    return open(filename, oflag);
}

static int gg_stat(char const* restrict path, struct stat* restrict buf) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_STAT, 0, 0, p, NULL, 0);
    return stat(p, buf);
}

static int gg_access(char const* path, int mode) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_ACCESS, 0, mode, p, NULL, 0);
    return access(p, mode);
}

static int gg_rename(char const* restrict old_name, char const* restrict new_name) {
    char const *o = ue_fix_filename(old_name);
    char const *n = ue_fix_filename(new_name);
    op_ring_emit(OP_K_FS_RENAME, 0, 0, o, NULL, 0);
    return rename(o, n);
}

static int gg_unlink(char const* path) {
    char const *p = ue_fix_filename(path);
    op_ring_emit(OP_K_FS_UNLINK, 0, 0, p, NULL, 0);
    return unlink(p);
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int gg_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[AppConfig shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);
        
        int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
        int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];
        
        if (time == 100000) {
            int timestamp = (int)[[NSDate date] timeIntervalSince1970];
            // If it sleeps too fast, increase counter
            if (timestamp - last_sleep_attempt < 2) {
                thread_sleep_counter++;
            } else {
                thread_sleep_counter = 1;
            }
            last_sleep_attempt = timestamp;
            thread_sleep_counters[threadKey] = @(thread_sleep_counter);
            last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            
        }
        
        if (thread_sleep_counter > 100) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(gg_open, open)
DYLD_INTERPOSE(gg_stat, stat)
DYLD_INTERPOSE(gg_access, access)
DYLD_INTERPOSE(gg_rename, rename)
DYLD_INTERPOSE(gg_unlink, unlink)
DYLD_INTERPOSE(gg_usleep, usleep)

@implementation GalgalLoader

/// Load per-app user tweaks from Frameworks/UserPlugins (populated by the host tweak
/// store sync): plain .dylib files directly, .framework bundles via their binary.
/// Dotfiles and the .disabled convention are skipped, mirroring the host scan, so the
/// GUI toggle and the loader can never disagree about what runs. Main queue only.
static BOOL OPLoadOnePlugin(NSString *path) {
    @try {
        void *handle = dlopen([path fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
        const char *err = dlerror();
        NSLog(@"[Ophanim] tweak %@: %s", [path lastPathComponent], handle ? "loaded" : (err ? err : "unknown"));
        op_ring_emit(OP_K_PROC_DLOPEN, 0, handle ? 0 : -1, [path fileSystemRepresentation], NULL, 0);
        return handle != NULL;
    } @catch (NSException *e) {
        NSLog(@"[Ophanim] tweak %@ threw: %@", [path lastPathComponent], e);
        return NO;
    }
}

// Recursive, deterministic plugin collection: depth-8, symlink-
// canonicalized visited set (no cycles), sorted order, `.dylib` plus
// `.framework` executable-path resolution, dotfiles/`.disabled` skipped,
// dangling symlinks tolerated. Pass-1 failures retry once (dependency order).
static void OPCollectPlugins(NSString *dir, NSMutableArray<NSString *> *out,
                             NSMutableSet<NSString *> *seen, int depth) {
    if (depth > 8) { return; }
    NSString *canon = [dir stringByResolvingSymlinksInPath];
    if (!canon || [seen containsObject:canon]) { return; }
    [seen addObject:canon];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names =
        [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."] || [name hasSuffix:@".disabled"]) { continue; }
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) { continue; }
        if (isDir) {
            if ([name hasSuffix:@".framework"]) {
                NSString *exe = [full stringByAppendingPathComponent:
                    [[name stringByDeletingPathExtension] lastPathComponent]];
                if ([fm fileExistsAtPath:exe]) { [out addObject:exe]; continue; }
            }
            OPCollectPlugins(full, out, seen, depth + 1);
        } else if ([name hasSuffix:@".dylib"]) {
            [out addObject:full];
        }
    }
}

static void OPLoadUserTweaks(void) {
    NSString *plugins = [[[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Frameworks"] stringByAppendingPathComponent:@"UserPlugins"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:plugins isDirectory:&isDir] || !isDir) { return; }
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    OPCollectPlugins(plugins, ordered, [NSMutableSet set], 0);
    NSMutableArray<NSString *> *retry = [NSMutableArray array];
    for (NSString *p in ordered) { if (!OPLoadOnePlugin(p)) { [retry addObject:p]; } }
    for (NSString *p in retry) { OPLoadOnePlugin(p); }
}

static void __attribute__((constructor)) initialize(void) {
    [Ophanim launch];

    // Ophanim instrumentation engine (embedded injection mode). Gated: starts only when the app's
    // config selects embedded injection - in sibling mode the standalone agent dylib owns the engine
    // and the embedded core stays dormant here.
    [OPBootstrap startEmbedded];

    // Inspect (Agent Mode): boot on the main queue - the pump's timer must attach to a
    // spinning runloop, and constructors are not guaranteed main-thread. Starts its command
    // pump only when the app opted in - otherwise one config read and out. Deliberately the
    // only addition here: no engine, no hooks, no loader behavior change for apps that never
    // enable it.
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [InspectBoot maybeStart];
        // User tweaks (Frameworks/UserPlugins, synced by the host tweak store): dlopen each
        // .dylib / framework binary on the main queue - constructors are not guaranteed
        // main-thread and dlopen runs initializers. Skips dotfiles + the .disabled
        // convention (mirrors the host store scan). RTLD_NOW fails loud in the log for
        // missing symbols instead of crashing later at first call. No-op when the dir
        // is absent (no tweaks installed).
        OPLoadUserTweaks();
    }];

    if (ue_status == 0) {
        if (GalgalInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [KeychainShim debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[AppConfig shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
