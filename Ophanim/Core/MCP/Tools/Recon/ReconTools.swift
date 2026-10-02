//
//  ReconTools.swift
//  Ophanim
//
//  Read-only binary/log recon tools. Binary surface (imports, symbols,
//  libraries, signatures) plus the behavior/privacy report.
//

import Foundation

/// Read-only binary/log recon tools.
///
/// Recon for hook targets: `app_imports` shows the interposable surface,
/// `find_symbols` locates `@objc` boundary candidates, `scan_signature`
/// finds inline-hook anchors.
enum ReconTools {

    // MARK: - Binary surface

    /// Produces a behavior/privacy report for an app from its captured events.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: The `ReportBuilder.report` JSON (hosts, identifiers, keychain,
    ///   crypto, jailbreak, pinning, launches, plus the `crash` section).
    static func analyzeApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        return try ToolRouter.json(ReportBuilder.report(bid))
    }

    /// Reports an app's dynamically-imported TLS/crypto/keychain/process symbols.
    ///
    /// This is the surface `interpose` can rebind. Crucial for statically-linked
    /// apps: even a self-contained binary imports the OS's crypto/TLS primitives
    /// (e.g. Secure Transport `SSLRead`/`SSLWrite`, `SecTrustEvaluate`), and
    /// those calls are interposable.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `interposableSymbols` count and the grouped `surface`.
    static func appImports(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let surface = AppQueryService.importSurface(bid)
        let total = surface.values.reduce(0) { $0 + $1.count }
        return try ToolRouter.json(["bundleID": bid, "interposableSymbols": total, "surface": surface])
    }

    /// Searches an app binary for symbols / ObjC class & selector names matching
    /// a keyword — recon for `@objc` boundary hook targets (then hook with
    /// `set_objc_hooks`).
    ///
    /// The keyword reaches process arguments, never a shell string; an
    /// allowlist keeps `nm`/`grep`/`demangle` inputs to literal substrings.
    ///
    /// - Parameter args: `bundleID` (required); `keyword` (required substring,
    ///   e.g. `Cronet`, `Response`, `didReceive`).
    /// - Returns: JSON with demangled `symbols`, Swift class names, and `selectors`.
    /// - Throws: `ToolRouter.bail` when `keyword` is missing or has unsafe characters.
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

    /// Lists runtime classes for an app: live runtime classes when Agent Mode
    /// runs, else static binary strings (limit ≤ 2000).
    ///
    /// Single live-first implementation (`InspectTools.classInventory`): one
    /// contract, one field shape — a second copy here would drift silently.
    ///
    /// - Parameter args: `bundleID` (required); `filter` (optional substring);
    ///   `limit` (default 200, max 2000).
    /// - Returns: The class-inventory JSON (`source` names `live` or `binary`).
    static func listClasses(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let filter = args["filter"] as? String
        let limit = min(ToolRouter.coerceInt(args, "limit") ?? 200, 2000)
        // Single live-first implementation (InspectTools.classInventory): one contract,
        // one field shape; a second copy here would drift silently.
        return try ToolRouter.json(InspectTools.classInventory(bid, filter: filter, limit: limit))
    }

    /// Linked libraries of an app binary (otool -L) — headless twin of the Recon
    /// libraries section. Read-only.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with the `binary` path, `libraries`, and `count`.
    /// - Throws: `ToolRouter.bail` when the app has no executable.
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
    ///
    /// - Parameter args: `bundleID` (required); `pattern` (required hex bytes
    ///   with `??` wildcards).
    /// - Returns: JSON with `pattern`, `hits`, `count`, and a `note`.
    /// - Throws: `ToolRouter.bail` when `pattern` is missing/malformed or the app
    ///   has no executable.
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
