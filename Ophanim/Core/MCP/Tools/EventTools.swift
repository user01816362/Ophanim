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
        // Single scan (limit 0 = all), then slice in memory; the cursor is the
        // newest event across all logs so the next call only sees newer rows.
        let all = ReportBuilder.events(bid, category: nil, search: nil, limit: 0)
        let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
        let slice = fresh.count > limit ? Array(fresh.suffix(limit)) : fresh
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let arr = (try? JSONSerialization.jsonObject(with: enc.encode(slice))) ?? []
        let cursor = (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
        return try ToolRouter.json(["count": slice.count, "cursor": cursor, "events": arr])
    }
}
