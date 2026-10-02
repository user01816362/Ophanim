//
//  OPSocketBridge.swift
//  OphanimCore
//
//  Bridge for the C socket/DNS interposers (connect/getaddrinfo). Connection + name-resolution
//  metadata under the .network category - complements the URLProtocol/TLS layers (which see HTTP),
//  capturing raw outbound endpoints and DNS lookups. Observe-only.
//

import Foundation

@objc(OPSocketBridge) public final class OPSocketBridge: NSObject {
    /// Logs one outbound connection attempt. Observe-only.
    ///
    /// - Parameter host: Destination host or IP string.
    /// - Parameter port: Destination port.
    /// - Parameter family: Address family (AF_INET6 vs IPv4/other).
    @objc public static func logConnect(host: NSString, port: Int32, family: Int32) {
        OPObserve.emit(category: .network) {
            let ctx = OPCallContext(category: .network, layer: .socket, api: "connect",
                                    fields: ["dest": "\(host):\(port)",
                                             "family": family == Int32(AF_INET6) ? "inet6" : "inet"],
                                    host: host as String)
            return (ctx, "connect \(host):\(port)")
        }
    }

    /// Logs one DNS lookup. Observe-only.
    ///
    /// - Parameter node: Hostname passed to getaddrinfo.
    @objc public static func logDNS(_ node: NSString) {
        OPObserve.emit(category: .network) {
            let ctx = OPCallContext(category: .network, layer: .socket, api: "getaddrinfo",
                                    fields: ["query": node as String], host: node as String)
            return (ctx, "DNS \(node)")
        }
    }
}
