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
                files.append(["path": f.path, "bytes": size ?? 0])
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
}
