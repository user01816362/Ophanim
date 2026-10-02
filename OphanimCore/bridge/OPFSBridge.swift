//
//  OPFSBridge.swift
//  OphanimCore
//
//  Filesystem logging for EMBEDDED mode. Galgal already DYLD_INTERPOSEs open/stat/access/rename/
//  unlink (for its Unreal path-rewriting), so - per the no-double-interpose rule - Galgal's
//  wrappers call this bridge inline rather than Ophanim re-hooking. Observe-only. High volume, so
//  it self-gates on the .filesystem category (cheap when disabled).
//

import Foundation

@objc(OPFSBridge) public final class OPFSBridge: NSObject {
    /// Logs one filesystem interpose hit from Galgal's wrappers. Observe-only.
    ///
    /// Takes a raw C string (not NSString): open/stat/access can be called by malloc itself during
    /// heap setup, so the caller MUST NOT allocate. The re-entrancy guard is set first, then the
    /// Swift String is built - any malloc→stat→hook re-entry then bails before allocating.
    ///
    /// - Parameter api: Intercepted API name (open/stat/access/rename/unlink).
    /// - Parameter cpath: Raw path bytes.
    @objc public static func log(api: NSString, cpath: UnsafePointer<CChar>?) {
        OPObserve.emit(category: .filesystem) {
            let path = cpath.map { String(cString: $0) } ?? ""
            let ctx = OPCallContext(category: .filesystem, layer: .interpose, api: api as String, path: path)
            return (ctx, "")
        }
    }
}
