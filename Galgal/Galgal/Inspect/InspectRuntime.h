//
//  InspectRuntime.h
//  Galgal
//

#import <Foundation/Foundation.h>

/// Every loaded ObjC class name. The malloc/free of the objc_copyClassList buffer stays in C
/// on purpose: handing that buffer to Swift balances the autoreleasing C return as an
/// Objective-C object and aborts the process (reproduced: __NSGenericDeallocHandler SIGTRAP).
/// Returned array is autoreleased.
NSArray<NSString *> *InspectCopyLoadedClassNames(void);

/// Full detail for one class by name (nil when unknown): method/ivar/property/protocol
/// inventory with explicit arg counts. Same memory law as above: every class_copy*
/// buffer is converted to Foundation values and freed in the same C scope; only
/// by-ref getters (no malloc at all) and borrowed *_get* strings cross no boundary.
/// Returned dictionary is autoreleased; all values are NSString/NSNumber/NSArray.
NSDictionary * _Nullable InspectCopyClassDetail(NSString *className);
