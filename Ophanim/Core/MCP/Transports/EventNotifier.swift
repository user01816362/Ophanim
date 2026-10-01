import Foundation

/// Best-effort server→client push for stdio `--mcp` children. One emitter thread per
/// process, 1 s cadence, read-only scans: notifications carry cursor + count only
/// (clients fetch bodies via tail_events), so there is no backlog to bound and
/// capture can never block. Disconnect needs no handling: stdio EOF exits the child
/// and the cursor is client-held, so a reconnected client re-polls or re-subscribes.
///
/// HTTP stays poll-only (use tail_events waitMs): push belongs to the process that
/// owns the stdout pipe, and only StdioTransport.run sets notifierActive.
enum EventNotifier {
    private static let lock = NSLock()
    private static var subs: [String: Double] = [:]  // bundleID -> cursor ms
    private static var running = false

    /// Register (or move) a subscription. Refuses outside a stdio child.
    static func subscribe(bundleID bid: String, since: Double) throws -> Double {
        guard MCPStdioTransport.notifierActive else {
            throw ToolRouter.bail("subscriptions need a stdio --mcp child; over HTTP use tail_events waitMs")
        }
        lock.lock()
        subs[bid] = since
        let start = !running
        running = true
        lock.unlock()
        if start {
            Thread.detachNewThread { emitter() }
        }
        return since
    }

    static func unsubscribe(bundleID bid: String?) -> Bool {
        lock.lock()
        if let bid {
            subs.removeValue(forKey: bid)
        } else {
            subs.removeAll()
        }
        let remaining = subs.count
        lock.unlock()
        return remaining == 0
    }

    static func active() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subs.keys)
    }

    private static func emitter() {
        while true {
            Thread.sleep(forTimeInterval: 1.0)
            lock.lock()
            let current = subs
            if current.isEmpty { running = false }
            lock.unlock()
            if current.isEmpty { return }  // last unsubscriber parks the thread; next subscribe restarts it
            for (bid, cursor) in current {
                let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
                let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > cursor }
                guard !fresh.isEmpty else { continue }
                let newest = (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
                let note: [String: Any] = ["jsonrpc": "2.0",
                                           "method": "notifications/events/added",
                                           "params": ["bundleID": bid, "cursor": newest,
                                                      "count": fresh.count]]
                if let data = try? JSONSerialization.data(withJSONObject: note,
                                                          options: [.withoutEscapingSlashes]) {
                    MCPStdioTransport.writeLine(data)
                }
                lock.lock()
                // Only advance past what we saw: a re-subscribe with an older cursor
                // during the scan must not be clobbered.
                if let cur = subs[bid], cur < newest { subs[bid] = newest }
                lock.unlock()
            }
        }
    }
}
