import Foundation

/// Read-only binary/log recon tools.
enum ReconTools {

    // MARK: - Binary surface

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
        // Single live-first implementation (InspectTools.classInventory): one contract,
        // one field shape; a second copy here would drift silently.
        return try ToolRouter.json(InspectTools.classInventory(bid, filter: filter, limit: limit))
    }

    /// Linked libraries of an app binary (otool -L) — headless twin of the Recon
    /// libraries section. Read-only.
    static func listLibraries(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let exe = AppQueryService.appExecutable(bid) else {
            throw ToolRouter.bail("no executable for \(bid)")
        }
        let out = try Shell.run(print: false, "/usr/bin/otool", "-L", exe.path)
        // Same parse as the Recon view (ReconView.parseLibraries): first line is the
        // binary path; each following line is "\t<path> (compat ...)".
        let libs = out.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let paren = t.range(of: " (") else { return t.isEmpty ? nil : t }
            return String(t[..<paren.lowerBound])
        }
        return try ToolRouter.json(["bundleID": bid, "binary": exe.path,
                             "libraries": Array(libs), "count": libs.count])
    }

    /// Byte-signature scan of an app binary ("1F 20 ?? D5", ?? = wildcard) —
    /// headless twin of the Recon signature scanner. Pure-Swift engine
    /// (ReconView.parsePattern/scan), capped at 500 hits. Read-only.
    // MARK: - Signature scan

    static func scanSignature(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let pattern = args["pattern"] as? String, !pattern.isEmpty else {
            throw ToolRouter.bail("pattern is required, e.g. \"1F 20 ?? D5\"")
        }
        guard let exe = AppQueryService.appExecutable(bid) else {
            throw ToolRouter.bail("no executable for \(bid)")
        }
        let bytes = ReconView.parsePattern(pattern)
        guard !bytes.isEmpty else {
            throw ToolRouter.bail("malformed pattern - use hex bytes with ?? wildcards, e.g. \"1F 20 ?? D5\"")
        }
        let (hits, note) = ReconView.scan(url: exe, pattern: bytes)
        return try ToolRouter.json(["bundleID": bid, "pattern": pattern,
                             "hits": hits, "count": hits.count, "note": note ?? ""])
    }
}
