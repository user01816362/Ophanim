//
//  OPTLSBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge the C SSL_read/SSL_write interposers call to log decrypted (plaintext)
//  TLS payloads through the agent. Observe-only: rewriting bytes mid-TLS-stream would corrupt the
//  connection, so the TLS layer captures ground-truth plaintext but defers blocking/rewrite to the
//  URLProtocol layer (which has clean request/response boundaries).
//

import Foundation

@objc(OPTLSBridge) public final class OPTLSBridge: NSObject {
    /// Logs decrypted TLS bytes from the C SSL_read/SSL_write interposers. Observe-only.
    ///
    /// - Parameter direction: 0 for read (inbound/response), 1 for write (outbound/request).
    /// - Parameter bytes: Plaintext bytes (copied, capped to bodyCap).
    /// - Parameter length: True byte count (logged even when the copy is capped).
    @objc public static func log(direction: Int32, bytes: UnsafeRawPointer?, length: Int32) {
        guard length > 0, let bytes = bytes else { return }
        let outbound = direction == 1
        OPObserve.emit(category: .network) {
            let cap = min(Int(length), OPAgent.shared.bodyCap)
            let data = Data(bytes: bytes, count: cap)
            let ctx = OPCallContext(category: .network, layer: .tls,
                                    api: outbound ? "SSL_write" : "SSL_read",
                                    fields: ["dir": outbound ? "write" : "read",
                                             "len": String(length)])
            if outbound { ctx.requestBody = data } else { ctx.responseBody = data }
            return (ctx, "TLS \(outbound ? "write" : "read") \(length)B")
        }
    }
}
