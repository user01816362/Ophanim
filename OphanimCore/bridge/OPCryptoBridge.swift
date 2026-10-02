//
//  OPCryptoBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge for the CommonCrypto interposers (CCCrypt/CCHmac). Observe-only; gates on
//  the .crypto category.
//

import Foundation

@objc(OPCryptoBridge) public final class OPCryptoBridge: NSObject {
    /// Logs one CommonCrypto interpose hit (CCCrypt/CCHmac). Observe-only.
    ///
    /// - Parameter api: Intercepted API name.
    /// - Parameter detail: Operation detail string from the interposer.
    @objc public static func log(api: NSString, detail: NSString) {
        OPObserve.emit(category: .crypto) {
            let ctx = OPCallContext(category: .crypto, layer: .interpose, api: api as String,
                                    fields: ["detail": detail as String])
            return (ctx, "\(api) \(detail)")
        }
    }
}
