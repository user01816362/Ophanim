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
    /// libraries section. Read-only. Versions parsed (not dropped), embedded
    /// vs system split, weak links marked (otool -l), one-level transitive
    /// closure over embedded frameworks.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with the `binary` path, `libraries` (paths, legacy
    ///   shape), `details` (path/version/weak/embedded), and `count`.
    /// - Throws: `ToolRouter.bail` when the app has no executable.
    static func listLibraries(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let exe = AppQueryService.appExecutable(bid) else {
            throw ToolRouter.bail("no executable for \(bid)")
        }
        let out = try Shell.run(print: false, "/usr/bin/otool", "-L", exe.path)
        // Same parse as the Recon view (ReconView.parseLibraries): first line is the
        // binary path; each following line is "\t<path> (compat ...)".
        struct Lib { var path: String; var compat: String; var current: String }
        let libs: [Lib] = out.split(separator: "\n").dropFirst().compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            var path = t, compat = "", current = ""
            if let paren = t.range(of: " (") {
                path = String(t[..<paren.lowerBound])
                let tail = String(t[paren.lowerBound...])
                if let m = tail.range(of: "compatibility version ([^,]+),", options: .regularExpression) {
                    compat = String(tail[m].dropFirst("compatibility version ".count).dropLast())
                }
                if let m = tail.range(of: "current version ([^\\)]+)", options: .regularExpression) {
                    current = String(tail[m].dropFirst("current version ".count))
                }
            }
            return Lib(path: path, compat: compat, current: current)
        }
        // Weak links via the shared otool -l parse (single shell-out).
        let weak: Set<String> = Set(AppQueryService.loadCommands(exe: exe)
            .filter { $0.cmd == "LC_LOAD_WEAK_DYLIB" }.map { $0.name })
        func isEmbedded(_ p: String) -> Bool {
            p.hasPrefix("@rpath") || p.hasPrefix("@executable_path") || p.contains(".framework/")
        }
        // One-level transitive closure over embedded frameworks (bounded).
        var transit: [String] = []
        for lib in libs.prefix(20) where isEmbedded(lib.path) {
            let fw = lib.path.replacingOccurrences(of: "@rpath/", with: "")
                .replacingOccurrences(of: "@executable_path/", with: "")
            let base = exe.deletingLastPathComponent().appendingPathComponent(fw)
            let fwBin = base.appendingPathComponent(base.deletingPathExtension().lastPathComponent)
            guard FileManager.default.fileExists(atPath: fwBin.path),
                  let sub = try? Shell.run(print: false, "/usr/bin/otool", "-L", fwBin.path) else { continue }
            for line in sub.split(separator: "\n").dropFirst().prefix(10) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let paren = t.range(of: " ("), !t.isEmpty { transit.append(String(t[..<paren.lowerBound])) }
            }
        }
        let details = libs.map { l -> [String: Any] in
            ["path": l.path, "compatibility": l.compat, "current": l.current,
             "weak": weak.contains(l.path), "embedded": isEmbedded(l.path)]
        }
        return try ToolRouter.json(["bundleID": bid, "binary": exe.path,
                             "libraries": libs.map { $0.path }, "details": details,
                             "transitiveEmbedded": Array(Set(transit)).sorted(),
                             "count": libs.count])
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

    /// Identity projection for an installed app: CDHash (Apple's identity
    /// primitive) + whole-file sha256 (change detection) + LC_UUID (build
    /// provenance) + signing authority + cryptid (FairPlay gate) + verify
    /// status. Read-only; every byte-export verb gates on this first.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON identity projection (empty-object bail when not installed).
    /// - Throws: `ToolRouter.bail` when the app is not installed.
    static func appIdentity(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        var payload = AppQueryService.appIdentity(bid)
        guard !payload.isEmpty else { throw ToolRouter.bail("no bundle for \(bid)") }
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }

    /// Whole-file SHA-256 of a bundle file (integrity, cache keys, dedup).
    ///
    /// - Parameter args: `bundleID` (required); `path` (bundle-relative file,
    ///   default = main executable).
    /// - Returns: JSON with `path`, `bytes`, and `sha256`.
    /// - Throws: `ToolRouter.bail` on escape, missing file, or hash failure.
    static func appHash(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let app = AppQueryService.appURL(bid) else { throw ToolRouter.bail("no bundle for \(bid)") }
        let rel = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let target: URL
        if let rel {
            guard !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else {
                throw ToolRouter.bail("path must be bundle-relative without .. segments")
            }
            target = app.appendingPathComponent(rel)
        } else {
            guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("no executable for \(bid)") }
            target = exe
        }
        guard target.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path) else {
            throw ToolRouter.bail("path escapes the bundle (symlink) - refused")
        }
        guard let hash = AppQueryService.sha256File(target.path) else {
            throw ToolRouter.bail("could not hash \(target.path)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        return try ToolRouter.json(["bundleID": bid, "path": target.path, "bytes": size, "sha256": hash])
    }

    /// Bundle Info.plist projection + semantic launch-planning checks
    /// (deep-link schemes → openURL targets, ATS exceptions, background
    /// modes, usage-description keys, version skew). Read-only; bundle path
    /// (not container-confined — reads the installed .app on disk).
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `plist` (JSON-safe dict) and `checks` (findings).
    /// - Throws: `ToolRouter.bail` when the app is not installed.
    static func appPlist(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let report = AppQueryService.appPlistReport(bid)
        guard !report.isEmpty else { throw ToolRouter.bail("no bundle for \(bid)") }
        var payload = report
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }

    /// Paged full symbol dump (no keyword guessing): same nm/demangle
    /// pipeline as find_symbols, sorted unique, sliced host-side.
    ///
    /// - Parameter args: `bundleID` (required); `kind` (`symbols`/`classes`/
    ///   `selectors`, default symbols); `page` (0-based, default 0);
    ///   `perPage` (default 200, max 500).
    /// - Returns: JSON with `total`, `page`, and `rows`.
    /// - Throws: `ToolRouter.bail` when the app has no executable.
    static func allSymbols(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let kind = (args["kind"] as? String).flatMap { ["symbols", "classes", "selectors"].contains($0) ? $0 : nil } ?? "symbols"
        let page = max(ToolRouter.coerceInt(args, "page") ?? 0, 0)
        let perPage = ToolRouter.coerceInt(args, "perPage") ?? 200
        var payload = AppQueryService.allSymbols(bid, kind: kind, page: page, perPage: perPage)
        guard !payload.isEmpty else { throw ToolRouter.bail("no executable for \(bid)") }
        payload["bundleID"] = bid
        payload["kind"] = kind
        return try ToolRouter.json(payload)
    }

    /// Raw protocol/conformance section dumps (v0): otool -s over ObjC
    /// protocol lists + Swift conformance sections, bounded text. Class and
    /// protocol names surface as strings; typed parsing is a later v1.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `sections` (name → capped dump lines).
    /// - Throws: `ToolRouter.bail` when the app has no executable.
    static func listProtocols(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        var payload = AppQueryService.protocolSections(bid)
        guard !payload.isEmpty else { throw ToolRouter.bail("no executable for \(bid)") }
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }

    /// Approximate string cross-refs: which data-section pointer slots hold
    /// offsets into matching cstrings (8-byte LE scan, labeled approximate).
    /// string → candidate data landlords → inline-hook anchors, without
    /// leaving MCP. Instruction-level xrefs need disassembly (blocked).
    ///
    /// - Parameter args: `bundleID` (required); `keyword` (required,
    ///   same allowlist as find_symbols).
    /// - Returns: JSON with `refs` and `approximate: true`.
    /// - Throws: `ToolRouter.bail` on missing/unsafe keyword or no executable.
    static func stringXrefs(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let kw = args["keyword"] as? String, !kw.isEmpty else { throw ToolRouter.bail("keyword is required") }
        guard kw.range(of: #"[^A-Za-z0-9_.\-:]"#, options: .regularExpression) == nil else {
            throw ToolRouter.bail("keyword contains unsafe characters (allowed: letters, digits, _ . - :)")
        }
        var payload = AppQueryService.stringXrefs(bid, kw)
        guard !payload.isEmpty else { throw ToolRouter.bail("no executable for \(bid)") }
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }
}
