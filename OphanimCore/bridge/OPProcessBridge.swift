//
//  OPProcessBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge for the C process/dylib interposers (dlopen/fork/posix_spawn). Observe-only
//  here; gating on the .process category happens inside (cheap when disabled).
//

import Foundation

@objc(OPProcessBridge) public final class OPProcessBridge: NSObject {
    /// Logs one process/dylib interpose hit (dlopen/fork/posix_spawn). Observe-only.
    ///
    /// - Parameter api: Intercepted API name.
    /// - Parameter detail: Path or detail string from the interposer.
    @objc public static func log(api: NSString, detail: NSString) {
        OPObserve.emit(category: .process) {
            let ctx = OPCallContext(category: .process, layer: .interpose, api: api as String,
                                    fields: ["detail": detail as String])
            return (ctx, "\(api) \(detail)")
        }
    }
}
