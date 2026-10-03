//
//  EventTools.swift
//  Ophanim
//
//  Event query tools. Filter/cursor/limit logic + event JSON encoding.
//

import Foundation

/// Event query tools. Filter/cursor/limit logic + event JSON encoding.
///
/// `tail_events` long-polls (bounded `waitMs`); `subscribe_events` pushes
/// cursor+count on stdout for stdio children (HTTP stays poll-only).
enum EventTools {

    // MARK: - Reads

    /// Returns captured instrumentation events for an app, newest last.
    ///
    /// - Parameter args: `bundleID` (required); `category` (optional filter);
    ///   `search` (optional case-insensitive substring over api/summary/fields);
    ///   `limit` (default 200, newest kept).
    /// - Returns: JSON with `count` and the `events` array.
    static func queryEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let category = args["category"] as? String
        let search = args["search"] as? String
        let limit = ToolRouter.coerceInt(args, "limit") ?? 200
        let events = ReportBuilder.events(bid, category: category, search: search, limit: limit)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(events)
        let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
        return try ToolRouter.json(["count": events.count, "events": arr])
    }

    /// Streams new captured events since a cursor, for live monitoring.
    ///
    /// Long-poll: blocks up to `waitMs` (cap 30 s) and returns early on new
    /// events, so a client can tail without a hot loop. `waitMs` 0 (default)
    /// is a single poll. `since: 0` (or omitted) returns the latest batch.
    ///
    /// - Parameter args: `bundleID` (required); `since` (cursor epoch ms,
    ///   default 0); `limit` (default 100, newest); `waitMs` (default 0, max 30000).
    /// - Returns: JSON with `count`, the next `cursor`, `waitedMs`, and `events`.
    static func tailEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = ToolRouter.coerceDouble(args, "since") ?? 0
        let limit = ToolRouter.coerceInt(args, "limit") ?? 100
        // Long-poll: block up to waitMs (cap 30 s) and return early on new events, so a
        // client can tail without a hot loop. waitMs 0 (default) = single poll, old shape.
        // One waiter per child at most (the handler is synchronous); the request counts
        // against the normal per-tool rate limit like any other call.
        let waitMs = min(max(ToolRouter.coerceInt(args, "waitMs") ?? 0, 0), 30000)
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)
        let started = Date()
        // Optional server-side filters (same semantics as query_events). The cursor
        // still advances on ALL events so filtered-out rows are never re-delivered.
        let category = args["category"] as? String
        let search = (args["search"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        func visible(_ e: OPEvent) -> Bool {
            if let category, e.category.rawValue != category { return false }
            guard let search, !search.isEmpty else { return true }
            return e.api.localizedCaseInsensitiveContains(search)
                || e.summary.localizedCaseInsensitiveContains(search)
                || e.fields.contains { $0.value.localizedCaseInsensitiveContains(search) }
        }
        while true {
            // Single scan (limit 0 = all), then slice in memory; the cursor is the
            // newest event across all logs so the next call only sees newer rows.
            let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
            let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
            let shown = fresh.filter(visible)
            let slice = shown.count > limit ? Array(shown.suffix(limit)) : shown
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
    ///
    /// - Parameter args: `bundleID` (required); `since` (cursor epoch ms, default 0).
    /// - Returns: JSON with `subscribed`, `bundleID`, `cursor`, and the fetch hint.
    /// - Throws: `ToolRouter.bail` when called outside a stdio `--mcp` child.
    // MARK: - Subscriptions

    static func subscribeEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = ToolRouter.coerceDouble(args, "since") ?? 0
        let cursor = try EventNotifier.subscribe(bundleID: bid, since: since)
        return try ToolRouter.json(["subscribed": true, "bundleID": bid, "cursor": cursor,
                             "note": "watch stdout for notifications/events/added; fetch bodies with tail_events"])
    }

    /// Stops push notifications: one bundleID, or all when omitted.
    ///
    /// - Parameter args: `bundleID` (optional; omit to unsubscribe all).
    /// - Returns: JSON with `subscribed: false`, `threadParked`, and `bundleID`
    ///   when one was named.
    static func unsubscribeEvents(_ args: [String: Any]) throws -> String {
        let bid = (args["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let parked = EventNotifier.unsubscribe(bundleID: bid)
        var payload: [String: Any] = ["subscribed": false, "threadParked": parked]
        if let bid { payload["bundleID"] = bid }
        return try ToolRouter.json(payload)
    }

    /// Replay-grade curl export rendered from a recorded network event (zero capture
    /// changes): method + url + req.* headers + decoded body when textual. Picks the
    /// newest URLSession request matching url/host/since; binary bodies are noted,
    /// never dumped. Prove-it: paste the command in Terminal, compare statuses.
    ///
    /// - Parameter args: `bundleID` (required); `since` (cursor epoch ms, default 0);
    ///   `url`/`host` (optional case-insensitive substring filters).
    /// - Returns: JSON with `bundleID`, `url`, the `curl` command, and a `note`
    ///   when the body was truncated or omitted.
    /// - Throws: `ToolRouter.bail` when no recorded request matches.
    // MARK: - Export

    static func exportCurl(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = ToolRouter.coerceDouble(args, "since") ?? 0
        let urlFilter = (args["url"] as? String)?.lowercased()
        let hostFilter = (args["host"] as? String)?.lowercased()
        let all = ReportBuilder.events(bid, category: "network", search: nil, limit: 0)
        let cands = all.filter { e in
            guard let url = e.fields["url"], !url.isEmpty,
                  e.timestamp.timeIntervalSince1970 * 1000 > since else { return false }
            if let uf = urlFilter, !url.lowercased().contains(uf) { return false }
            if let hf = hostFilter,
               !(e.fields["host"]?.lowercased().contains(hf) ?? url.lowercased().contains(hf)) {
                return false
            }
            return true
        }
        guard let e = cands.last, let url = e.fields["url"] else {
            throw ToolRouter.bail("no recorded request matches"
                + (urlFilter.map { " url '\($0)'" } ?? "")
                + (hostFilter.map { " host '\($0)'" } ?? ""))
        }
        // index: 0 = newest (default), 1 = one before, ... Fail stated past the end.
        let index = max(ToolRouter.coerceInt(args, "index") ?? 0, 0)
        guard index < cands.count,
              let pick = cands.dropLast(index + 1).last,
              let pickURL = pick.fields["url"] else {
            throw ToolRouter.bail("index \(index) out of range (\(cands.count) matching requests)")
        }
        let e = pick
        let url = pickURL
        func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl", "-X", e.fields["method"] ?? "GET", sh(url)]
        for (k, v) in e.fields.filter({ $0.key.hasPrefix("req.") }).sorted(by: { $0.key < $1.key }) {
            let name = String(k.dropFirst(4))
            if name.lowercased() == "content-length" { continue }
            parts += ["-H", sh("\(name): \(v)")]
        }
        var note: String? = nil
        if let body = e.requestBody, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                parts += ["--data-raw", sh(String(text.prefix(16384)))]
                if text.count > 16384 { note = "body truncated to 16384 chars" }
            } else {
                note = "binary body (\(body.count) bytes) omitted - add --data-binary yourself"
            }
        }
        var payload: [String: Any] = ["bundleID": bid, "url": url, "curl": parts.joined(separator: " ")]
        if index > 0 { payload["index"] = index }
        if let note { payload["note"] = note }
        return try ToolRouter.json(payload)
    }
}
