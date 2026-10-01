//
//  OPCrashRecord.swift
//  OphanimCore (shared: guest engine + host app)
//
//  One schema for every crash-cause artifact, whoever writes it (guest exception/signal
//  recorders, host kill-silent correlator) and whoever reads it (LogViewer, analyze_app).
//  All fields defaulted: forward/backward tolerant decode, so old readers skip new fields
//  and new readers accept old files. Frames are dladdr-symbolicated STRINGS (never raw
//  addresses - guest ASLR makes addresses meaningless off-process) and carry reasons, not
//  payloads: no bodies, no PII beyond what the NDJSON already holds.
//
//  Deliberately NO Sendable conformance: the sibling agent compiles this file with plain
//  swiftc (no -swift-version flag), so it must stay in the lowest-common Swift dialect.
//  All uses are synchronous value copies, which need no conformance.
//

import Foundation

/// Kinds, closed set. `kill-silent` = guest died with no writer artifact (SIGKILL,
/// force-quit, crash-before-writer); `clean-exit` = orderly marker, the healthy control.
public enum OPCrashKind: String, Codable {
    case objcException = "objc-exception"
    case signal
    case watchdogSuspected = "watchdog-suspected"
    case jetsamSuspected = "jetsam-suspected"
    case killSilent = "kill-silent"
    case cleanExit = "clean-exit"
}

public struct OPCrashRecord: Codable {
    public var version: Int = 1
    /// Run identity, shared with the NDJSON run file stem: "<stamp>-<pid>".
    public var runId: String = ""
    public var bundleID: String = ""
    public var pid: Int = 0
    public var capturedAt: String = ""
    public var kind: OPCrashKind = .killSilent
    public var signal: Int? = nil
    public var signalName: String? = nil
    public var machException: String? = nil
    public var terminationReason: String? = nil
    public var exceptionName: String? = nil
    public var exceptionReason: String? = nil
    public var lastHook: String? = nil
    public var frames: [String] = []
    public var ringDropped: Int? = nil
    public var agentMode: Bool = false
    public var configHash: String? = nil

    public init() {}

    // Lenient decoding (OPConfig convention): property defaults do NOT excuse missing
    // keys in synthesized Decodable - every field reads decodeIfPresent so old readers
    // skip new fields and new readers accept old files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OPCrashRecord()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? d.runId
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? d.bundleID
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? d.pid
        capturedAt = try c.decodeIfPresent(String.self, forKey: .capturedAt) ?? d.capturedAt
        kind = try c.decodeIfPresent(OPCrashKind.self, forKey: .kind) ?? d.kind
        signal = try c.decodeIfPresent(Int.self, forKey: .signal)
        signalName = try c.decodeIfPresent(String.self, forKey: .signalName)
        machException = try c.decodeIfPresent(String.self, forKey: .machException)
        terminationReason = try c.decodeIfPresent(String.self, forKey: .terminationReason)
        exceptionName = try c.decodeIfPresent(String.self, forKey: .exceptionName)
        exceptionReason = try c.decodeIfPresent(String.self, forKey: .exceptionReason)
        lastHook = try c.decodeIfPresent(String.self, forKey: .lastHook)
        frames = try c.decodeIfPresent([String].self, forKey: .frames) ?? d.frames
        ringDropped = try c.decodeIfPresent(Int.self, forKey: .ringDropped)
        agentMode = try c.decodeIfPresent(Bool.self, forKey: .agentMode) ?? d.agentMode
        configHash = try c.decodeIfPresent(String.self, forKey: .configHash)
    }
}
