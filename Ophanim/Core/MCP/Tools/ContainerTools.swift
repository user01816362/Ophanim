import Foundation

/// Container/log/profile/data tools. Finder reveal has no headless meaning and
/// stays GUI-only.
enum ContainerTools {
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

    static func clearLogs(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        var candidates: [URL] = []
        for dir in ReportBuilder.logDirs(bid) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            candidates.append(contentsOf: entries.filter { $0.pathExtension == "ndjson" })
        }
        let bytes = candidates.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 ?? 0)
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

    static func containerInfo(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        return try ToolRouter.json(ContainerService.containerReport(bid))
    }

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

    static func clearContainer(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let scope = args["scope"] as? String,
              ["caches", "data", "keychain"].contains(scope) else {
            throw ToolRouter.bail("scope is required: caches, data, or keychain")
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
        default:
            targets = KeyCoverKey(appBundleID: bid).allFiles.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        let bytes = targets.compactMap { ContainerService.directorySize($0) }.reduce(0, +)
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
