//
//  OPKeychainBridge.swift
//  OphanimCore
//
//  Keychain logging for the EMBEDDED mode. Galgal already DYLD_INTERPOSEs SecItem* (for its
//  keychain emulation), so - per the no-double-interpose rule - Ophanim does not re-hook them;
//  instead Galgal's existing SecItem wrappers call this bridge inline. Observe-only.
//

import Foundation

@objc(OPKeychainBridge) public final class OPKeychainBridge: NSObject {
    /// Logs one SecItem call from Galgal's existing interposers. Observe-only, never dumps secrets.
    ///
    /// - Parameter api: SecItem API name.
    /// - Parameter query: Query dictionary (only class/account/service/access-group are read).
    /// - Parameter status: OSStatus from the call.
    @objc public static func log(api: NSString, query: NSDictionary?, status: Int32) {
        OPObserve.emit(category: .keychain) {
            var fields: [String: String] = ["status": String(status)]
            // Pull the human-meaningful attributes without dumping secret material.
            if let q = query {
                if let v = q["class"] { fields["class"] = "\(v)" }       // kSecClass
                if let v = q["acct"] as? String { fields["account"] = v } // kSecAttrAccount
                if let v = q["svce"] as? String { fields["service"] = v } // kSecAttrService
                if let v = q["agrp"] as? String { fields["accessGroup"] = v } // kSecAttrAccessGroup
            }
            let ctx = OPCallContext(category: .keychain, layer: .interpose, api: api as String, fields: fields)
            return (ctx, "\(api) status=\(status)")
        }
    }
}
