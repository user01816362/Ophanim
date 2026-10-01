//
//  InspectRuntime.m
//  Galgal
//

#import "InspectRuntime.h"
#import <objc/runtime.h>

NSArray<NSString *> *InspectCopyLoadedClassNames(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (!list) {
        return @[];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        [names addObject:NSStringFromClass(list[i])];
    }
    free(list);
    return names;
}

static NSString *InspectFirstTypeCode(const char *encoding) {
    if (!encoding || !encoding[0]) { return @"?"; }
    // Skip qualifiers (r n N o O R V) to the first real type code.
    const char *p = encoding;
    while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
           *p == 'O' || *p == 'R' || *p == 'V') { p++; }
    if (!*p) { return @"?"; }
    return [NSString stringWithFormat:@"%c", *p];
}

static NSArray *InspectMethodInfo(Class cls, BOOL classMethods, BOOL *truncated) {
    if (!cls) { return @[]; }
    Class target = classMethods ? object_getClass(cls) : cls;
    if (!target) { return @[]; }
    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    if (!list) { return @[]; }
    NSUInteger cap = classMethods ? 200 : 500;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:MIN(count, (unsigned int)cap)];
    for (unsigned int i = 0; i < count && [out count] < cap; i++) {
        Method m = list[i];
        const char *sel = sel_getName(method_getName(m));
        int explicit = (int)method_getNumberOfArguments(m) - 2; // minus self + _cmd
        char ret[8] = {0};
        method_getReturnType(m, ret, sizeof(ret));
        [out addObject:@{
            @"sel": sel ? [NSString stringWithUTF8String:sel] : @"?",
            @"args": @(explicit < 0 ? 0 : explicit),
            @"ret": InspectFirstTypeCode(ret),
        }];
    }
    if (count > [out count]) { *truncated = YES; }
    free(list);
    return out;
}

NSDictionary * _Nullable InspectCopyClassDetail(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { return nil; }
    BOOL truncated = NO;
    NSMutableArray<NSString *> *supers = [NSMutableArray array];
    for (Class s = class_getSuperclass(cls); s && [supers count] < 8; s = class_getSuperclass(s)) {
        [supers addObject:NSStringFromClass(s)];
    }
    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    NSMutableArray *ivarInfo = [NSMutableArray array];
    if (ivars) {
        for (unsigned int i = 0; i < ic && [ivarInfo count] < 200; i++) {
            const char *n = ivar_getName(ivars[i]);
            const char *t = ivar_getTypeEncoding(ivars[i]);
            [ivarInfo addObject:@{
                @"name": n ? [NSString stringWithUTF8String:n] : @"?",
                @"type": InspectFirstTypeCode(t),
            }];
        }
        if (ic > [ivarInfo count]) { truncated = YES; }
        free(ivars);
    }
    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    NSMutableArray<NSString *> *propInfo = [NSMutableArray array];
    if (props) {
        for (unsigned int i = 0; i < pc && [propInfo count] < 200; i++) {
            const char *a = property_getAttributes(props[i]);
            if (a) { [propInfo addObject:[NSString stringWithUTF8String:a]]; }
        }
        if (pc > [propInfo count]) { truncated = YES; }
        free(props);
    }
    unsigned int rc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(cls, &rc);
    NSMutableArray<NSString *> *protoNames = [NSMutableArray array];
    if (protos) {
        for (unsigned int i = 0; i < rc && [protoNames count] < 100; i++) {
            const char *n = protocol_getName(protos[i]);
            if (n) { [protoNames addObject:[NSString stringWithUTF8String:n]]; }
        }
        if (rc > [protoNames count]) { truncated = YES; }
        free(protos);
    }
    return @{
        @"name": NSStringFromClass(cls),
        @"isMeta": @(class_isMetaClass(cls)),
        @"superclasses": supers,
        @"methods": InspectMethodInfo(cls, NO, &truncated),
        @"classMethods": InspectMethodInfo(cls, YES, &truncated),
        @"ivars": ivarInfo,
        @"properties": propInfo,
        @"protocols": protoNames,
        @"truncated": @(truncated),
    };
}
