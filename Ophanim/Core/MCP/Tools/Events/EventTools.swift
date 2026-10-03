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

    /// Named event cursors (fences): `event_mark` pins "now" per app so a
    /// later `events_since_mark` (or `tap_and_observe`) returns exactly the
    /// window — "these 3 requests were caused by this tap" without re-pulling
    /// full logs. Host memory only; marks die with the process.
    private final class MarkStore: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [String: Double] = [:]
        func set(bundleID bid: String, name: String, cursor: Double) {
            lock.withLock { marks["\(bid)::\(name)"] = cursor }
        }
        func get(bundleID bid: String, name: String) -> Double? {
            lock.withLock { marks["\(bid)::\(name)"] }
        }
    }

    private static let marks = MarkStore()

    /// Newest-event cursor (epoch ms) for an app; 0 when no events yet.
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Returns: The newest event timestamp in ms, else 0.
    private static func newestCursor(_ bid: String) -> Double {
        let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
        return (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
    }

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

    /// Pins the current newest-event cursor under a name for later
    /// `events_since_mark` / `tap_and_observe` windows. Read-only against
    /// capture (host-memory cursor only).
    ///
    /// - Parameter args: `bundleID` (required); `name` (optional, default
    ///   "default").
    /// - Returns: JSON with `mark`, `cursor`, and `bundleID`.
    static func eventMark(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let name = ((args["name"] as? String)?.isEmpty == false) ? (args["name"] as? String)! : "default"
        let cursor = newestCursor(bid)
        marks.set(bundleID: bid, name: name, cursor: cursor)
        return try ToolRouter.json(["bundleID": bid, "mark": name, "cursor": cursor])
    }

    /// Events after a named mark (exact-window causality without chatter
    /// re-pull). Same filter semantics as `tail_events`; the cursor still
    /// advances on ALL events.
    ///
    /// - Parameter args: `bundleID` (required); `mark` (default "default");
    ///   `category`/`search` (optional filters); `limit` (default 100, newest).
    /// - Returns: JSON with `count`, the next `cursor`, and `events`.
    /// - Throws: `ToolRouter.bail` naming `event_mark` when the mark is unknown.
    static func eventsSinceMark(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let name = ((args["mark"] as? String)?.isEmpty == false) ? (args["mark"] as? String)! : "default"
        guard let since = marks.get(bundleID: bid, name: name) else {
            throw ToolRouter.bail(ToolRouter.recovery(what: "unknown event mark '\(name)' for \(bid)",
                next: "event_mark {bundleID, name} to pin a cursor, then retry"))
        }
        let limit = ToolRouter.coerceInt(args, "limit") ?? 100
        let category = args["category"] as? String
        let search = (args["search"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let all = ReportBuilder.events(bid, category: category, search: nil, limit: 0)
        let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
        let shown: [OPEvent]
        if let search, !search.isEmpty {
            shown = fresh.filter {
                $0.api.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
                || $0.fields.contains { $0.value.localizedCaseInsensitiveContains(search) }
            }
        } else {
            shown = fresh
        }
        let slice = shown.count > limit ? Array(shown.suffix(limit)) : shown
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let arr = (try? JSONSerialization.jsonObject(with: enc.encode(slice))) ?? []
        let cursor = (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
        return try ToolRouter.json(["bundleID": bid, "mark": name, "count": slice.count,
                             "cursor": cursor, "events": arr])
    }

    /// Diffs two capture cursors: groups events in (sinceA, sinceB] by api
    /// with counts + first/last timestamps. The tap→traffic-attribution
    /// read: cursor → act → diff. Read-only over already-captured logs.
    ///
    /// - Parameter args: `bundleID` (required); `sinceA`, `sinceB` (cursor
    ///   epoch ms); `category`/`search` (optional filters).
    /// - Returns: JSON with `groups` (api → count/first/last), `total`.
    static func diffEvents(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let sinceA = ToolRouter.coerceDouble(args, "sinceA") else {
            throw ToolRouter.bail("diff_events needs sinceA (cursor epoch ms from tail_events or event_mark)")
        }
        guard let sinceB = ToolRouter.coerceDouble(args, "sinceB") else {
            throw ToolRouter.bail("diff_events needs sinceB (a later cursor epoch ms)")
        }
        let category = args["category"] as? String
        let search = (args["search"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let all = ReportBuilder.events(bid, category: category, search: nil, limit: 0)
        let window = all.filter {
            let ms = $0.timestamp.timeIntervalSince1970 * 1000
            return ms > sinceA && ms <= sinceB
        }.filter {
            guard let search, !search.isEmpty else { return true }
            return $0.api.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
                || $0.fields.contains { $0.value.localizedCaseInsensitiveContains(search) }
        }
        var groups: [String: [String: Any]] = [:]
        let iso = ISO8601DateFormatter()
        for e in window {
            let ms = e.timestamp.timeIntervalSince1970 * 1000
            if var g = groups[e.api] {
                g["count"] = (g["count"] as? Int ?? 0) + 1
                g["last"] = iso.string(from: e.timestamp)
                g["lastMs"] = ms
                groups[e.api] = g
            } else {
                groups[e.api] = ["count": 1, "first": iso.string(from: e.timestamp),
                                 "firstMs": ms, "last": iso.string(from: e.timestamp), "lastMs": ms]
            }
        }
        return try ToolRouter.json(["bundleID": bid, "total": window.count, "groups": groups])
    }

    /// Hook/event coverage summary: which instrumented apis fired since a
    /// cursor, with counts + first/last + dispositions seen. Converts the
    /// event firehose into a flow map ("which of my hooks fired during that
    /// tap?") without client-side paging. Host-only NDJSON aggregation.
    ///
    /// - Parameter args: `bundleID` (required); `since` (cursor epoch ms,
    ///   default 0); `limit` (default 200 apis, most-fired first).
    /// - Returns: JSON with `apis` (api → count/first/last/dispositions),
    ///   `apiCount`, `eventCount`.
    static func hookCoverage(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let since = ToolRouter.coerceDouble(args, "since") ?? 0
        let limit = min(max(ToolRouter.coerceInt(args, "limit") ?? 200, 1), 1000)
        let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
        let window = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
        var agg: [String: (count: Int, first: Date, last: Date, disps: Set<String>)] = [:]
        for e in window {
            if var a = agg[e.api] {
                a.count += 1; a.last = e.timestamp; a.disps.insert(e.disposition.rawValue)
                agg[e.api] = a
            } else {
                agg[e.api] = (1, e.timestamp, e.timestamp, [e.disposition.rawValue])
            }
        }
        let iso = ISO8601DateFormatter()
        let apis = agg.sorted { $0.value.count > $1.value.count }.prefix(limit).map { api, a -> [String: Any] in
            ["api": api, "count": a.count, "first": iso.string(from: a.first),
             "last": iso.string(from: a.last), "dispositions": a.disps.sorted()]
        }
        return try ToolRouter.json(["bundleID": bid, "apiCount": agg.count,
                             "eventCount": window.count, "apis": Array(apis)])
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
        guard !cands.isEmpty else {
            throw ToolRouter.bail("no recorded request matches"
                + (urlFilter.map { " url '\($0)'" } ?? "")
                + (hostFilter.map { " host '\($0)'" } ?? ""))
        }
        // index: 0 = newest (default), 1 = one before, ... Fail stated past the end.
        let index = max(ToolRouter.coerceInt(args, "index") ?? 0, 0)
        guard index < cands.count,
              let pick = cands.dropLast(index + 1).last,
              let pickURL = pick.fields["url"] else {
            throw ToolRouter.bail(ToolRouter.recovery(what: "index \(index) out of range (\(cands.count) matching requests)",
                next: "lower index below \(cands.count) or drop the url/host filter, then retry"))
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
