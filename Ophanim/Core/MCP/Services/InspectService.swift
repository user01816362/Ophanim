//
//  InspectService.swift
//  Ophanim
//
//  Host side of InspectProtocol (ported): single-slot synchronous transactions
//  over the shared log directory, pump-liveness reads, app-alive rule.

import Foundation
import AppKit

enum InspectControl {
    /// Serializes inspect transactions across all apps. Two concurrent hosts sharing one
    /// single-slot command file corrupt each other (second overwrites the first; the first's
    /// timeout withdrawal then deletes the second's pending command), so the slot is one
    /// client at a time. Inspect calls are rare and seconds-long; coarse is correct here.
    static let slotLock = NSLock()

    /// Inspect log-directory for an app (created on demand). Every inspect
    /// transaction (command slot, responses, heartbeats, snapshots) lives here.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The directory URL.
    static func directory(for bundleID: String) -> URL {
        let dir = OPPaths.logDirectory(forBundleID: bundleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pump-alive freshness (phase-5 observability): the guest rewrites this file per minute
    /// while serving. Nil = never beat (pump never started = ON needs relaunch, or OFF).
    /// Readers state the timestamp; they never guess between "slow op" and "silent pump"
    /// without it - the timeout path below shows how.
    static func pumpAliveSince(bundleID: String) -> Date? {
        let beat = directory(for: bundleID).appendingPathComponent(InspectWire.pumpAlive)
        if let mtime = (try? beat.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           mtime != .distantPast { return mtime }
        guard let text = try? String(contentsOf: beat, encoding: .utf8),
              let date = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return date
    }

    /// Single source of truth for "is the hosted app alive": every MCP tool must ask this,
    /// never its own private definition. Proven live: a client-spawned `--mcp` child sees an
    /// empty/different `runningApplications` list while the same binary spawned from a shell
    /// screenshots the running app fine - the observer's spawn context leaks into the answer.
    /// So NSWorkspace is one input, not the verdict. Order: workspace (cheapest), pump
    /// heartbeat freshness (guest proof-of-life, visible from any context), recent capture
    /// writes (flowing events mean a live process - the same evidence the log-backed tools
    /// already trust). Windows (150 s beat, 120 s log) bound the stale-after-death skew.
    static func isAppRunning(bundleID bid: String) -> Bool {
        // Authoritative first: the GUI watched this pid launch or die. A recorded exit
        // short-circuits everything below (no stale heartbeat can overrule a witnessed
        // death); a fresh launch mark answers without consulting any observer context.
        if let decided = OPAppLiveness.authoritativeState(bundleID: bid) { return decided }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid }) {
            return true
        }
        if let beat = pumpAliveSince(bundleID: bid), Date().timeIntervalSince(beat) < MCPTimeouts.heartbeatGrace {
            return true
        }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory(for: bid), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-MCPTimeouts.logFresh)
        for f in items where f.pathExtension == "ndjson" {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, m > cutoff { return true }
        }
        return false
    }

    /// Sweep orphaned responses (and stale claim files from a guest that died mid-op):
    /// after a host timeout the guest's late answer is never collected, and without this the
    /// log dir accumulates one file per timed-out call.
    static func sweepOrphans(in dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-MCPTimeouts.orphanSweep)
        for item in items where item.lastPathComponent.hasPrefix(InspectWire.responsePrefix)
            || item.lastPathComponent.hasSuffix(InspectWire.claimSuffix) {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (date ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    /// One synchronous inspect transaction through the single-slot command file.
    ///
    /// Writes the command atomically, polls for the id-matched response until
    /// the bound, then withdraws the command so a late guest poll never runs a
    /// stale op twice (a withdrawn tap cannot double-fire). Held under
    /// `slotLock` for the whole transaction: concurrent hosts share one slot,
    /// so the second call waits instead of overwriting the first.
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Parameter op: The inspect operation.
    /// - Parameter elementId: Target element (element ops; mode-bound).
    /// - Parameter x: Horizontal tap/pick point in 0...1 (gesture ops).
    /// - Parameter y: Vertical tap/pick point in 0...1 (gesture ops).
    /// - Parameter mode: Tree mode (element ids only resolve in their own mode).
    /// - Parameter filter: Optional tree substring filter.
    /// - Parameter limit: Class-list cap (class ops).
    /// - Parameter x1: Swipe start x in 0...1.
    /// - Parameter y1: Swipe start y in 0...1.
    /// - Parameter x2: Swipe end x in 0...1.
    /// - Parameter y2: Swipe end y in 0...1.
    /// - Parameter steps: Swipe interpolation steps.
    /// - Parameter text: Replacement text (set_text).
    /// - Parameter depthLimit: Tree depth cap (agent-narrowable).
    /// - Parameter nodeLimit: Tree node cap (agent-narrowable).
    /// - Parameter className: Class name (class-detail op).
    /// - Parameter timeout: Transaction bound (default `MCPTimeouts.inspect`).
    /// - Returns: The guest's response.
    /// - Throws: `ToolRouter.ToolError` when the guest answers failure, or on
    ///   timeout — naming the pump silence (stale heartbeat vs never beat) and
    ///   the relaunch fix.
    static func transact(bundleID bid: String, op: InspectOp,
                         elementId: String? = nil, x: Double? = nil, y: Double? = nil,
                         mode: InspectMode? = nil, filter: String? = nil, limit: Int? = nil,
                         x1: Double? = nil, y1: Double? = nil,
                         x2: Double? = nil, y2: Double? = nil,
                         steps: Int? = nil, text: String? = nil,
                         depthLimit: Int? = nil, nodeLimit: Int? = nil,
                         className: String? = nil,
                         timeout: TimeInterval = MCPTimeouts.inspect) throws -> InspectResponse {
        // Held for the whole transaction (bounded by timeout): serializes the single slot.
        // Blocks the calling thread like launch_app's 120s semaphore does - on the stdio
        // transport that stalls other requests meanwhile, which is the documented cost of a
        // synchronous poll loop, not a deadlock: every path exits by deadline.
        slotLock.lock()
        defer { slotLock.unlock() }
        let id = UUID().uuidString
        let cmd = InspectCommand(id: id, op: op, mode: mode, filter: filter,
                                 elementId: elementId, x: x, y: y,
                                 x1: x1, y1: y1, x2: x2, y2: y2, steps: steps,
                                 depthLimit: depthLimit, nodeLimit: nodeLimit,
                                 limit: limit, className: className, text: text)
        let dir = directory(for: bid)
        sweepOrphans(in: dir)
        try JSONEncoder().encode(cmd)
            .write(to: dir.appendingPathComponent(InspectWire.command), options: .atomic)
        let rspURL = dir.appendingPathComponent(InspectWire.responseName(for: id))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? Data(contentsOf: rspURL),
               let rsp = try? JSONDecoder().decode(InspectResponse.self, from: raw),
               rsp.id == id {
                try? FileManager.default.removeItem(at: rspURL)
                if rsp.ok { return rsp }
                throw ToolRouter.ToolError(message: rsp.error ?? "inspect failed without detail")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // Withdraw the command: a late guest poll must never run a stale tap twice.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(InspectWire.command))
        // Stale heartbeat + agentMode-on names the relaunch explicitly (phase-5): the old
        // generic "is the app running" message sent operators chasing a running app whose
        // guest pump was simply never booted (ON needs relaunch) or already turned off.
        if let since = pumpAliveSince(bundleID: bid) {
            throw ToolRouter.ToolError(
                message: "inspect timed out after \(Int(timeout))s - guest pump silent since \(since) - "
                    + "relaunch the app with Agent Mode on")
        }
        throw ToolRouter.ToolError(
            message: "inspect timed out after \(Int(timeout))s - no pump heartbeat for \(bid) - "
                + "relaunch the app with Agent Mode on")
    }
}

/// Opt-in auto-capture around hand ops (`snapshot:"pre"|"post"|"both"` on tap_element,
/// swipe, set_text). Parsed here so the schema enum and the dispatcher cannot drift.
enum SnapshotCaptureArg {
    static let name = "snapshot"
    nonisolated(unsafe) static let schema: [String: Any] = [
        "type": "string", "enum": ["none", "pre", "post", "both"],
        "description": "Pin UI snapshots around the op for flip analysis with inspect_diff "
            + "(pre/post/both; default none). Each leg costs a full tree transaction."]
    /// Parses the `snapshot` arg (`none`/`pre`/`post`/`both`, default none).
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Returns: The (pre, post) capture flags.
    /// - Throws: `ToolRouter.bail` on any other value.
    static func parse(_ args: [String: Any]) throws -> (pre: Bool, post: Bool) {
        guard let raw = args[name] as? String else { return (false, false) }
        switch raw {
        case "none": return (false, false)
        case "pre": return (true, false)
        case "post": return (false, true)
        case "both": return (true, true)
        default:
            throw ToolRouter.bail(
                "snapshot must be none, pre, post, or both - got '\(raw)'")
        }
    }
}
