//
//  ContainerTools.swift
//  Ophanim
//
//  Container/log/profile/data tools. Finder reveal has no headless meaning and
//  stays GUI-only.
//

import Foundation

/// Container/log/profile/data tools. Finder reveal has no headless meaning and
/// stays GUI-only.
enum ContainerTools {

    // MARK: - Keychain projection (read-only)

    /// One-call dump of an app's ChainGuard (emulated keychain) items. The store
    /// is plaintext SQLite while KeyCover stays hard-disabled, so this projects
    /// service/account/secret triples operators otherwise dig out by hand.
    /// Sensitive by owner's standing directive (own apps only): values are NOT
    /// masked — never paste this output into shared contexts.
    ///
    /// - Parameter args: `bundleID` (required); `limit` (default 100, cap 500).
    /// - Returns: JSON with per-table `items` (service/account/secret).
    /// - Throws: `ToolRouter.bail` when no ChainGuard db exists for the app.
    static func keychainItems(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let limit = min(max(ToolRouter.coerceInt(args, "limit") ?? 100, 1), 500)
        let db = KeyCover.chainGuardPath
            .appendingPathComponent(bid)
            .appendingPathExtension(KeyCoverKey.decryptedKeyExtension)
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw ToolRouter.bail("no ChainGuard database for \(bid) (chainGuard may be off or the app never touched keychain)")
        }
        let tableRows = try sqliteJSON(db: db,
            sql: "SELECT name FROM sqlite_master WHERE type='table';")
        let tables = Set(tableRows.compactMap { $0["name"] as? String })
        var out: [[String: Any]] = []
        var total = 0
        for t in ["genp", "inet", "idnt", "cert", "keys"] where tables.contains(t) {
            let colRows = try sqliteJSON(db: db, sql: "PRAGMA table_info(\"\(t)\");")
            let cols = Set(colRows.compactMap { $0["name"] as? String })
            func has(_ c: String) -> Bool { cols.contains(c) }
            var select: [String] = []
            for c in ["agrp", "acct", "svce", "labl", "desc"] where has(c) { select.append(c) }
            if has("v_Data") {
                select.append("CASE WHEN typeof(v_Data)='blob' THEN '<binary ' || length(v_Data) || ' bytes>' " +
                              "WHEN length(v_Data)>2000 THEN substr(v_Data,1,2000) || '…' ELSE v_Data END AS secret")
            }
            guard !select.isEmpty else { continue }
            let quoted = "\"" + t + "\""
            let rows = try sqliteJSON(db: db, sql: "SELECT \(select.joined(separator: ", ")) FROM \(quoted);")
            for var r in rows {
                if total >= limit { break }
                r["table"] = t
                out.append(r); total += 1
            }
            if total >= limit { break }
        }
        return try ToolRouter.json(["bundleID": bid, "items": out, "count": out.count])
    }

    // MARK: - Container file read + prefs edit

    /// Read one file inside the app's readable roots (container/logs): plists
    /// decode to JSON, text is capped, binary reports as base64-capped.
    ///
    /// - Parameter args: `bundleID` + `path` (required; absolute or container-relative); `limit` bytes (default 8192, cap 65536).
    /// - Returns: JSON with `path`, `bytes`, `encoding` (plist|utf8|base64), `content`.
    /// - Throws: `ToolRouter.bail` outside allowed roots or unreadable.
    static func containerRead(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            throw ToolRouter.bail("path is required")
        }
        let limit = min(max(ToolRouter.coerceInt(args, "limit") ?? 8192, 1), 65536)
        let expanded = ToolRouter.expandedURL(raw)
        let url: URL
        if expanded.path.hasPrefix("/") {
            url = expanded.standardizedFileURL
        } else {
            // Relative paths try each readable root, with and without the Data/
            // segment (data containers nest content under Data/, the composed
            // container path does not) — first hit wins, stated miss otherwise.
            let bases = ContainerService.readableRoots(bid)
            let candidates = bases + bases.map { $0.appendingPathComponent("Data") }
            guard let hit = candidates.lazy.map({ $0.appendingPathComponent(raw).standardizedFileURL })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ToolRouter.bail("no such file under the app's container/logs: \(raw)")
            }
            url = hit
        }
        guard ContainerService.isReadable(url, bundleID: bid) else {
            throw ToolRouter.bail("path is outside the app's container/logs: \(raw)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw ToolRouter.bail("no such file: \(url.path)")
        }
        if url.pathExtension.lowercased() == "plist",
           let obj = PlistReader.plistDict(at: url) {
            return try ToolRouter.json(["bundleID": bid, "path": url.path,
                                 "encoding": "plist", "content": ContainerService.jsonSafe(obj)])
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ToolRouter.bail("unreadable file: \(url.path)")
        }
        let bytes = data.count
        let slice = data.prefix(limit)
        if let text = String(data: slice, encoding: .utf8), !text.isEmpty {
            var payload: [String: Any] = ["bundleID": bid, "path": url.path, "bytes": bytes,
                                   "encoding": "utf8", "content": text]
            if bytes > limit { payload["truncated"] = true }
            return try ToolRouter.json(payload)
        }
        return try ToolRouter.json(["bundleID": bid, "path": url.path, "bytes": bytes,
                             "encoding": "base64",
                             "content": slice.base64EncodedString(),
                             "truncated": bytes > limit])
    }

    /// Set one scalar preference in the app's preferences plist (feature flags,
    /// onboarding resets, seeded state). Strings/numbers/booleans only; nested
    /// values fail stated. Destructive: dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `key` (required); `value` (string/number/bool); `dryRun`.
    /// - Returns: JSON preview or confirmation with old/new values.
    /// - Throws: `ToolRouter.bail` on missing plist, non-dict root, or non-scalar value.
    static func setPref(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let key = args["key"] as? String, !key.isEmpty else {
            throw ToolRouter.bail("key is required")
        }
        let prefs = AppContainer(bundleId: bid).userPrefsUrl
        guard var dict = PlistReader.plistDict(at: prefs) else {
            throw ToolRouter.bail("no readable preferences plist for \(bid)")
        }
        let old = dict[key]
        let value = args["value"]
        guard value is String || value is Int || value is Double || value is Bool else {
            throw ToolRouter.bail("value must be a string, number, or boolean (nested values unsupported)")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "key": key,
                                 "old": old.map(ContainerService.jsonSafe) ?? NSNull(),
                                 "new": ContainerService.jsonSafe(value as Any)])
        }
        dict[key] = value
        do {
            try PlistReader.writePlistDict(dict, to: prefs)
        } catch {
            throw ToolRouter.bail("preferences write failed: \(error.localizedDescription)")
        }
        return try ToolRouter.json(["bundleID": bid, "key": key,
                             "old": old.map(ContainerService.jsonSafe) ?? NSNull(),
                             "new": ContainerService.jsonSafe(value as Any)])
    }

    /// Removes one top-level preferences key (scalar flags like
    /// `loggedIn`/`onboarded` for onboarding-reset recipes). Same path
    /// confinement as setPref; scalar top-level keys only. Destructive:
    /// dryRun previews by default. Note cfprefsd staleness: write-while-
    /// running may not be seen until relaunch (set → terminate → launch).
    ///
    /// - Parameter args: `bundleID` (required); `key` (required).
    /// - Returns: Dry-run JSON with `old`, or confirmation with removed `old`.
    /// - Throws: `ToolRouter.bail` on missing key/plist or absent entry.
    static func deletePref(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let key = args["key"] as? String, !key.isEmpty else {
            throw ToolRouter.bail("key is required")
        }
        let prefs = AppContainer(bundleId: bid).userPrefsUrl
        guard var dict = PlistReader.plistDict(at: prefs) else {
            throw ToolRouter.bail("no readable preferences plist for \(bid)")
        }
        guard let old = dict[key] else {
            throw ToolRouter.bail("no such preferences key '\(key)' for \(bid)")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "key": key,
                                 "old": ContainerService.jsonSafe(old)])
        }
        dict.removeValue(forKey: key)
        do {
            try PlistReader.writePlistDict(dict, to: prefs)
        } catch {
            throw ToolRouter.bail("preferences write failed: \(error.localizedDescription)")
        }
        return try ToolRouter.json(["bundleID": bid, "key": key, "removed": true,
                             "old": ContainerService.jsonSafe(old)])
    }

    // MARK: - SQLite browser (read-only, host-side)

    /// Roots a database path is allowed to come from: the app's composed +
    /// resolved containers and its log dirs. Anything else fails stated — the
    /// sqlite CLI must never be pointed at arbitrary host paths.
    private static func sqliteRoots(_ bid: String) -> [URL] {
        var roots = [AppContainer(bundleId: bid).containerUrl]
        if let real = Uninstaller.containerURL(for: bid) { roots.append(real) }
        roots.append(contentsOf: ReportBuilder.logDirs(bid))
        return roots
    }

    /// Resolve a database locator to a readable sqlite file inside the allowed
    /// roots. `db` may be a full path or a filename substring (first match,
    /// searched recursively to depth 6 — app-group nesting like
    /// Documents/group.X/.../Library/.../Databases/).
    private static func resolveDatabase(_ bid: String, _ db: String) throws -> URL {
        let fm = FileManager.default
        let direct = URL(fileURLWithPath: db).standardizedFileURL
        let roots = sqliteRoots(bid).map { $0.standardizedFileURL }
        func inside(_ u: URL) -> Bool {
            roots.contains { u.path.hasPrefix($0.path) }
        }
        if fm.fileExists(atPath: direct.path), inside(direct),
           ["sqlite", "db"].contains(direct.pathExtension.lowercased()) {
            return direct
        }
        var found: [URL] = []
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            var depthGuard = 0
            for case let f as URL in en {
                depthGuard += 1
                if depthGuard > 4000 { break }
                guard ["sqlite", "db"].contains(f.pathExtension.lowercased()),
                      f.lastPathComponent.localizedCaseInsensitiveContains(db) else { continue }
                found.append(f)
                if found.count >= 10 { break }
            }
            if found.count >= 10 { break }
        }
        guard let first = found.first else {
            throw ToolRouter.bail("no sqlite database matching '\(db)' under the app's container/logs")
        }
        return first
    }

    /// Run a read-only query via the OS sqlite3 CLI (no package dep). `-readonly`
    /// plus identifier validation at the call sites (never interpolate raw input).
    private static func sqliteJSON(db: URL, sql: String) throws -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-json", db.path, sql]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ToolRouter.bail("sqlite query failed (exit \(p.terminationStatus))")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // Empty result sets print zero bytes (not `[]`) in -json mode.
        if data.isEmpty || data.allSatisfy({ $0 == 0x0A || $0 == 0x20 }) { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ToolRouter.bail("sqlite returned unparseable output")
        }
        return arr
    }

    /// List tables (+ row counts) of an app-container sqlite database.
    ///
    /// - Parameter args: `bundleID` (required); `db` (required path or filename substring).
    /// - Returns: JSON with resolved `path`, `tables` (name + rows), `count`.
    static func sqliteTables(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let db = args["db"] as? String, !db.isEmpty else {
            throw ToolRouter.bail("db is required (path or filename substring)")
        }
        let url = try resolveDatabase(bid, db)
        let rows = try sqliteJSON(db: url,
            sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        var tables: [[String: Any]] = []
        for r in rows {
            guard let name = r["name"] as? String else { continue }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let cnt = try sqliteJSON(db: url, sql: "SELECT COUNT(*) AS n FROM \(quoted);")
            tables.append(["name": name, "rows": (cnt.first?["n"] as? Int) ?? 0])
        }
        return try ToolRouter.json(["bundleID": bid, "path": url.path,
                             "tables": tables, "count": tables.count])
    }

    /// Read rows of one table (validated against the table list first, so the
    /// name can never inject SQL).
    ///
    /// - Parameter args: `bundleID`, `db`, `table` (all required); `limit` (default 50, cap 200).
    /// - Returns: JSON with `rows` (capped), `count`, and whether output truncated.
    static func sqliteRows(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let db = args["db"] as? String, !db.isEmpty,
              let table = args["table"] as? String, !table.isEmpty else {
            throw ToolRouter.bail("db and table are required")
        }
        let limit = min(max(ToolRouter.coerceInt(args, "limit") ?? 50, 1), 200)
        let url = try resolveDatabase(bid, db)
        let known = try sqliteJSON(db: url,
            sql: "SELECT name FROM sqlite_master WHERE type='table';")
        guard known.compactMap({ $0["name"] as? String }).contains(table) else {
            throw ToolRouter.bail("no such table '\(table)' in \(url.lastPathComponent)")
        }
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var rows = try sqliteJSON(db: url, sql: "SELECT * FROM \(quoted) LIMIT \(limit + 1);")
        let truncated = rows.count > limit
        if truncated { rows = Array(rows.prefix(limit)) }
        // Cap cell text so one blob column can't flood the response.
        let capped = rows.map { row -> [String: Any] in
            var out: [String: Any] = [:]
            for (k, v) in row {
                if let s = v as? String, s.count > 2000 { out[k] = String(s.prefix(2000)) + "…" }
                else { out[k] = v }
            }
            return out
        }
        return try ToolRouter.json(["bundleID": bid, "path": url.path, "table": table,
                             "rows": capped, "count": capped.count, "truncated": truncated])
    }

    // MARK: - Logs

    /// Reports capture-log locations and ndjson files with sizes.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with the primary `path`, scanned dirs, `files`, and `count`.
    static func getLogPath(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let dirs = ReportBuilder.logDirs(bid)
        let primary = OPPaths.logDirectory(forBundleID: bid)
        var files: [[String: Any]] = []
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for f in entries where f.pathExtension == "ndjson" {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                files.append(["path": f.path, "bytes": size])
            }
        }
        return try ToolRouter.json(["bundleID": bid, "path": primary.path, "alsoScanned": dirs.map(\.path),
                             "files": files, "count": files.count])
    }

    /// Deletes an app's capture logs, byte-counted. Destructive (idempotent):
    /// dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` (required); `dryRun: false` deletes.
    /// - Returns: Dry-run JSON with `wouldRemove` + `bytes`, or the result with
    ///   `removed` + `count` + `bytes`.
    static func clearLogs(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        var candidates: [URL] = []
        for dir in ReportBuilder.logDirs(bid) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            candidates.append(contentsOf: entries.filter { $0.pathExtension == "ndjson" })
        }
        let bytes = candidates.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "wouldRemove": candidates.map(\.path),
                                 "count": candidates.count, "bytes": bytes])
        }
        var removed: [String] = []
        for url in candidates {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(url.path) }
        }
        return try ToolRouter.json(["bundleID": bid, "removed": removed, "count": removed.count, "bytes": bytes])
    }

    /// Resolves and reports an app's data container (real path, not composed).
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: The `ContainerService.containerReport` JSON.
    static func containerInfo(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        return try ToolRouter.json(ContainerService.containerReport(bid))
    }

    // MARK: - Profiles

    /// Lists an app's container profiles plus the active one and a live check.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `active`, `profiles`, and `liveExists`.
    static func listProfiles(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        return try ToolRouter.json([
            "bundleID": bid,
            "active": ContainerProfiles.activeName(bundleID: bid),
            "profiles": ContainerProfiles.profiles(bundleID: bid),
            "liveExists": FileManager.default.fileExists(
                atPath: ContainerProfiles.liveURL(bundleID: bid).path)
        ])
    }

    /// Snapshots the live container into a named profile. Destructive: dryRun
    /// previews by default.
    ///
    /// - Parameter args: `bundleID` + `name` (required); `dryRun: false` creates.
    /// - Returns: Dry-run JSON with `wouldCopyLive`, or confirmation with `created`.
    /// - Throws: `ToolRouter.bail` when `name` is missing (create errors propagate).
    static func createProfile(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        let liveExists = FileManager.default.fileExists(
            atPath: ContainerProfiles.liveURL(bundleID: bid).path)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "name": name,
                                 "wouldCopyLive": liveExists])
        }
        try ContainerProfiles.create(bundleID: bid, name: name)
        return try ToolRouter.json(["bundleID": bid, "created": name, "copiedLive": liveExists])
    }

    /// Swaps the live container to a profile. Refuses while the app runs.
    /// Destructive: dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `name` (required); `dryRun: false` switches.
    /// - Returns: Dry-run JSON with `active`/`appRunning`/`wouldRefuse`, or
    ///   confirmation with the new `active` profile.
    /// - Throws: `ToolRouter.bail` when `name` is missing, or the switch refuses
    ///   (active profile, app running).
    static func switchProfile(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        let running = ContainerProfiles.isRunning(bundleID: bid)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "name": name,
                                 "active": ContainerProfiles.activeName(bundleID: bid),
                                 "appRunning": running,
                                 "wouldRefuse": running])
        }
        try ContainerProfiles.switchTo(bundleID: bid, name: name)
        return try ToolRouter.json(["bundleID": bid, "active": name])
    }

    /// Deletes a container profile. Destructive: dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `name` (required); `dryRun: false` deletes.
    /// - Returns: Dry-run JSON with `isActive`, or confirmation with `removed`.
    /// - Throws: `ToolRouter.bail` when `name` is missing (remove errors propagate).
    static func removeProfile(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "name": name,
                                 "isActive": name == ContainerProfiles.activeName(bundleID: bid)])
        }
        try ContainerProfiles.remove(bundleID: bid, name: name)
        return try ToolRouter.json(["bundleID": bid, "removed": name])
    }

    // MARK: - Destructive container reset

    /// Wipes one container scope: caches, data, keychain, or the single
    /// preferences plist. The data scope also wipes snapshots + bookmarks (marks
    /// outliving a data wipe would point at a UI that no longer exists).
    /// Destructive (idempotent): dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` (required); `scope` (required: `caches`,
    ///   `data`, `keychain`, `preferences`); `dryRun: false` wipes.
    /// - Returns: Dry-run JSON with `targets` + `bytes`, or the result with
    ///   `removed` + `bytes`.
    /// - Throws: `ToolRouter.bail` when `scope` is missing/invalid or no data
    ///   container resolves.
    static func clearContainer(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let scope = args["scope"] as? String,
              ["caches", "data", "keychain", "preferences"].contains(scope) else {
            throw ToolRouter.bail("scope is required: caches, data, keychain, or preferences")
        }
        let targets: [URL]
        switch scope {
        case "caches":
            let caches = ContainerProfiles.liveURL(bundleID: bid)
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
            targets = FileManager.default.fileExists(atPath: caches.path) ? [caches] : []
        case "data":
            guard let real = Uninstaller.containerURL(for: bid) else {
                throw ToolRouter.bail("no data container could be resolved for \(bid); it may never have launched")
            }
            targets = [real]
        case "preferences":
            // Surgical single-plist wipe — same path the library context menu
            // deletes (HostedAppView.deletePreferences / AppContainer.userPrefsUrl).
            let prefs = AppContainer(bundleId: bid).userPrefsUrl
            targets = FileManager.default.fileExists(atPath: prefs.path) ? [prefs] : []
        default:
            targets = KeyCoverKey(appBundleID: bid).allFiles.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        let bytes: Int64 = targets.reduce(0) { total, url in
            // directorySize enumerates directories; single-file scopes (preferences)
            // read the file size directly.
            if scope == "preferences" {
                return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total + (ContainerService.directorySize(url) ?? 0)
        }
        // Scope data wipes what the app knew: the container plus the agent analysis that
        // describes it (snapshot timeline + bookmarks). Marks outliving a data wipe would
        // point at a UI that no longer exists; uninstall already takes both, so the wipe
        // matches it. Caches/keychain scopes stay surgical.
        let analysisFiles: [URL]
        if scope == "data" {
            let (snaps, _) = SnapshotStore.inventory(bundleID: bid)
            let marks = BookmarkStore.fileURL(bundleID: bid)
            analysisFiles = snaps + ([marks].filter {
                FileManager.default.fileExists(atPath: $0.path) })
        } else {
            analysisFiles = []
        }
        var analysisBytes: Int64 = 0
        for url in analysisFiles {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                analysisBytes += Int64(size)
            }
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "scope": scope,
                                 "targets": targets.map(\.path) + analysisFiles.map(\.path),
                                 "bytes": bytes + analysisBytes])
        }
        var removed: [String] = []
        for target in targets {
            if (try? FileManager.default.removeItem(at: target)) != nil {
                removed.append(target.path)
            }
        }
        if scope == "data" {
            // SnapshotStore.clear deletes the timeline (manifests + sidecars) and posts
            // the reset notification; analysisFiles (inventoried above, pre-deletion)
            // supplies the exact response paths. The marks file rides in the same list
            // when it existed.
            _ = SnapshotStore.clear(bundleID: bid)
            let marks = BookmarkStore.fileURL(bundleID: bid)
            if FileManager.default.fileExists(atPath: marks.path) {
                try? FileManager.default.removeItem(at: marks)
            }
            removed.append(contentsOf: analysisFiles.map(\.path))
        }
        return try ToolRouter.json(["bundleID": bid, "scope": scope, "removed": removed,
                             "bytes": bytes + analysisBytes])
    }

    // MARK: - Backup and restore

    /// Archives the live container to a zip (`ditto -c -k`). Destructive:
    /// dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `destPath` (required); `dryRun: false`
    ///   archives.
    /// - Returns: Dry-run JSON with `source`/`destination`/`wouldOverwrite`, or
    ///   confirmation with `source`/`destination`/`bytes`.
    /// - Throws: `ToolRouter.bail` when `destPath` is missing or no data
    ///   container resolves.
    static func backupContainer(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let dest = args["destPath"] as? String, !dest.isEmpty else { throw ToolRouter.bail("destPath is required") }
        guard let real = Uninstaller.containerURL(for: bid) else {
            throw ToolRouter.bail("no data container could be resolved for \(bid); it may never have launched")
        }
        let destURL = ToolRouter.expandedURL(dest)
        let bytes = ContainerService.directorySize(real) ?? 0
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "source": real.path,
                                 "destination": destURL.path, "bytes": bytes,
                                 "wouldOverwrite": FileManager.default.fileExists(atPath: destURL.path)])
        }
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Shell.run(print: false, "/usr/bin/ditto", "-c", "-k", "--sequesterRsrc",
                      real.path, destURL.path)
        return try ToolRouter.json(["bundleID": bid, "source": real.path,
                             "destination": destURL.path, "bytes": bytes])
    }

    /// Restores the live container from a zip archive. Refuses while the app
    /// runs. Destructive: dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `archivePath` (required); `dryRun: false`
    ///   restores.
    /// - Returns: Dry-run JSON with `archive`/`destination`/`liveExists`, or
    ///   confirmation with `archive`/`destination`.
    /// - Throws: `ToolRouter.bail` when `archivePath` is missing or names no
    ///   archive, or `OphanimError.containerRunning` while the app runs.
    static func restoreContainer(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let archive = args["archivePath"] as? String, !archive.isEmpty else { throw ToolRouter.bail("archivePath is required") }
        let archiveURL = ToolRouter.expandedURL(archive)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ToolRouter.bail("no such archive: \(archiveURL.path)")
        }
        if ContainerProfiles.isRunning(bundleID: bid) {
            throw OphanimError.containerRunning
        }
        let live = ContainerProfiles.liveURL(bundleID: bid)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "archive": archiveURL.path,
                                 "destination": live.path,
                                 "liveExists": FileManager.default.fileExists(atPath: live.path)])
        }
        if FileManager.default.fileExists(atPath: live.path) {
            try FileManager.default.removeItem(at: live)
        }
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Shell.run(print: false, "/usr/bin/ditto", "-x", "-k", archiveURL.path, live.path)
        return try ToolRouter.json(["bundleID": bid, "archive": archiveURL.path, "destination": live.path])
    }

    /// Exports one bundle-relative file outside the bundle (bounded, hashed,
    /// symlink-escape-proof). Never writes into the bundle. Explicit verb,
    /// no preview branch.
    ///
    /// - Parameter args: `bundleID` (required); `src` (bundle-relative path);
    ///   `dest` (destination file path, required); `maxBytes` (default
    ///   52428800); `overwrite` (default false).
    /// - Returns: JSON with `src`, `dest`, `size`, before/after sha256.
    /// - Throws: `ToolRouter.bail` on escape, caps, refusal, or I/O failure.
    static func appExportFile(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let src = args["src"] as? String, !src.isEmpty else { throw ToolRouter.bail("src is required (bundle-relative path)") }
        guard let dest = args["dest"] as? String, !dest.isEmpty else { throw ToolRouter.bail("dest is required (outside file path)") }
        guard let app = AppQueryService.appURL(bid) else { throw ToolRouter.bail("no bundle for \(bid)") }
        let maxBytes = ToolRouter.coerceInt(args, "maxBytes") ?? 50 * 1024 * 1024
        var payload = try AppQueryService.exportFile(app: app, src: src,
                                                     dest: ToolRouter.expandedURL(dest),
                                                     maxBytes: maxBytes,
                                                     overwrite: (args["overwrite"] as? Bool) ?? false)
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }

    /// Zips a whole .app for external testing (seal-preserving ditto;
    /// identity sidecar beside the zip). Refuses FairPlay-encrypted mains
    /// and broken seals (override labeled). Explicit verb, no preview branch.
    ///
    /// - Parameter args: `bundleID` (required); `dest` (destination zip path,
    ///   required); `allowBrokenSeal` (default false).
    /// - Returns: JSON with `zip`, `sha256_zip`, `bytes`, `sealValid`,
    ///   `sealLabel`, `identitySidecar`.
    /// - Throws: `ToolRouter.bail` on encryption, seal, or ditto failure.
    static func appExportBundle(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let dest = args["dest"] as? String, !dest.isEmpty else { throw ToolRouter.bail("dest is required (zip path)") }
        guard let app = AppQueryService.appURL(bid) else { throw ToolRouter.bail("no bundle for \(bid)") }
        let identity = AppQueryService.appIdentity(bid)
        var payload = try AppQueryService.exportBundle(app: app, dest: ToolRouter.expandedURL(dest),
                                                        allowBrokenSeal: (args["allowBrokenSeal"] as? Bool) ?? false,
                                                        identity: identity)
        payload["bundleID"] = bid
        return try ToolRouter.json(payload)
    }
}
