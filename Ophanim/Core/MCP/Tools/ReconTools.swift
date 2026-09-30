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
}
