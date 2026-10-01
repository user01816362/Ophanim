import Foundation

/// Event query tools. Filter/cursor/limit logic + event JSON encoding.
enum EventTools {
    static func queryEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let category = args["category"] as? String
        let search = args["search"] as? String
        let limit = (args["limit"] as? Int) ?? 200
        let events = ReportBuilder.events(bid, category: category, search: search, limit: limit)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(events)
        let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
        return try ToolRouter.json(["count": events.count, "events": arr])
    }

    static func tailEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = (args["since"] as? Double) ?? Double((args["since"] as? Int) ?? 0)
        let limit = (args["limit"] as? Int) ?? 100
        // Long-poll: block up to waitMs (cap 30 s) and return early on new events, so a
        // client can tail without a hot loop. waitMs 0 (default) = single poll, old shape.
        // One waiter per child at most (the handler is synchronous); the request counts
        // against the normal per-tool rate limit like any other call.
        let waitMs = min(max((args["waitMs"] as? Int) ?? 0, 0), 30000)
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)
        let started = Date()
        while true {
            // Single scan (limit 0 = all), then slice in memory; the cursor is the
            // newest event across all logs so the next call only sees newer rows.
            let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
            let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
            let slice = fresh.count > limit ? Array(fresh.suffix(limit)) : fresh
            if !slice.isEmpty || Date() >= deadline {
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                let arr = (try? JSONSerialization.jsonObject(with: enc.encode(slice))) ?? []
                let cursor = (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
                let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
                return try ToolRouter.json(["count": slice.count, "cursor": cursor,
                                     "waitedMs": waitedMs, "events": arr])
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Best-effort push: register this stdio child for cursor+count notifications
    /// (`notifications/events/added` on stdout). Bodies still come via tail_events.
    /// Refuses outside a stdio child (HTTP stays poll-only).
    static func subscribeEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = (args["since"] as? Double) ?? Double((args["since"] as? Int) ?? 0)
        let cursor = try EventNotifier.subscribe(bundleID: bid, since: since)
        return try ToolRouter.json(["subscribed": true, "bundleID": bid, "cursor": cursor,
                             "note": "watch stdout for notifications/events/added; fetch bodies with tail_events"])
    }

    static func unsubscribeEvents(_ args: [String: Any]) throws -> String {
        let bid = (args["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let parked = EventNotifier.unsubscribe(bundleID: bid)
        var payload: [String: Any] = ["subscribed": false, "threadParked": parked]
        if let bid { payload["bundleID"] = bid }
        return try ToolRouter.json(payload)
    }
}
