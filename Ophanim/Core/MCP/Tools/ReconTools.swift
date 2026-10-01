import Foundation

/// Read-only binary/log recon tools.
enum ReconTools {
    static func analyzeApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        return try ToolRouter.json(ReportBuilder.report(bid))
    }

    static func appImports(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let surface = AppQueryService.importSurface(bid)
        let total = surface.values.reduce(0) { $0 + $1.count }
        return try ToolRouter.json(["bundleID": bid, "interposableSymbols": total, "surface": surface])
    }

    static func findSymbols(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let kw = args["keyword"] as? String, !kw.isEmpty else { throw ToolRouter.bail("keyword is required") }
        // Injection guard: the keyword reaches process arguments, never a shell
        // string. Allowlist keeps nm/grep/demangle inputs to literal substrings.
        guard kw.range(of: #"[^A-Za-z0-9_.\-:]"#, options: .regularExpression) == nil else {
            throw ToolRouter.bail("keyword contains unsafe characters (allowed: letters, digits, _ . - :)")
        }
        return try ToolRouter.json(AppQueryService.findSymbols(bid, kw))
    }

    static func listClasses(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let filter = args["filter"] as? String
        let limit = min((args["limit"] as? Int) ?? 200, 2000)
        // Live-first when Agent Mode runs (generated classes included), static
        // strings otherwise (ObjC classes invisible statically - stated).
        var liveClasses: [String]? = nil
        var liveError: String? = nil
        if (try? InspectGate.requireLive(bundleID: bid)) != nil {
            do {
                let rsp = try InspectControl.transact(bundleID: bid, op: .classes,
                                                      filter: filter, limit: limit)
                liveClasses = rsp.classes ?? []
            } catch let e as ToolRouter.ToolError {
                liveError = e.message
            }
        }
        let (exe, staticClasses, staticSelectors) = try ReportBuilder.staticClassInventory(bid, filter: filter, limit: limit)
        let classes = liveClasses ?? staticClasses
        var payload: [String: Any] = ["bundleID": bid, "executable": exe,
                             "source": liveClasses == nil ? "static" : "live",
                             "classes": Array(classes.prefix(limit)),
                             "selectors": Array(staticSelectors.prefix(limit)),
                             "count": classes.count + staticSelectors.count]
        if liveClasses == nil {
            payload["note"] = "static binary strings only: misses generated classes and plain ObjC classes - launch with Agent Mode for the live list"
        }
        if let liveError { payload["liveError"] = liveError }
        return try ToolRouter.json(payload)
    }
}
