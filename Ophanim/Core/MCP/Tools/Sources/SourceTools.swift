import Foundation

/// App-Sources tools: list/add/remove feeds, install a feed app (optionally
/// pinned to a version). The stores are synchronous, so handlers call them
/// directly; only the async fetch and the install settle loop need bridging.
enum SourceTools {

    // MARK: - Feed registry

    static func listSources(_ args: [String: Any]) throws -> String {
        let feeds: [[String: Any]] = AppSourcesStore.shared.sources.map { item in
            var feed: [String: Any] = [
                "url": item.url.absoluteString,
                "displayName": item.displayName,
                "appCount": item.source?.apps.count ?? 0,
            ]
            if item.isLoading { feed["loading"] = true }
            if let error = item.error { feed["error"] = error }
            if let news = item.source?.news, !news.isEmpty {
                feed["news"] = news.map { ["title": $0.title, "caption": $0.caption ?? ""] }
            }
            return feed
        }
        return try ToolRouter.json(["count": feeds.count, "sources": feeds])
    }

    // MARK: - Feed writes

    static func addSource(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw ToolRouter.bail("url is required") }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "url": raw])
        }
        final class ErrorBox: @unchecked Sendable {
            var value: String?
        }
        let box = ErrorBox()
        let sema = DispatchSemaphore(value: 0)
        Task {
            box.value = await AppSourcesStore.shared.addSource(from: raw)
            sema.signal()
        }
        sema.wait()
        if let addError = box.value { throw ToolRouter.bail(addError) }
        return try ToolRouter.json(["subscribed": raw])
    }

    static func removeSource(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw ToolRouter.bail("url is required") }
        guard let target = AppSourcesStore.shared.sources.first(where: {
            $0.url.absoluteString == raw || $0.url.host == raw
        }) else { throw ToolRouter.bail("no subscribed source matches \(raw)") }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "url": target.url.absoluteString])
        }
        AppSourcesStore.shared.removeSource(target)
        return try ToolRouter.json(["removed": target.url.absoluteString])
    }

    // MARK: - Install and lookup

    static func installSourceApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let version = args["version"] as? String
        let (app, picked) = try sourceApp(bundleID: bid, version: version)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "version": picked.version,
                                 "build": picked.buildVersion ?? "",
                                 "bytes": picked.size ?? 0])
        }
        SourceInstalls.shared.start(app: app, version: picked)
        switch try awaitSourceIdle(bundleID: bid, timeout: MCPTimeouts.install) {
        case .idle:
            let installed = SourceInstalls.shared.installedVersion(for: bid)?.version
            guard installed != nil else { throw ToolRouter.bail("install failed for \(bid) - see the Ophanim log") }
            return try ToolRouter.json(["installed": bid, "version": installed ?? ""])
        case .failed(let message):
            throw ToolRouter.bail("install failed for \(bid): \(message)")
        case .paused:
            return try ToolRouter.json(["paused": bid, "hint": "resume from the Sources window"])
        case .downloading, .installing:
            throw ToolRouter.bail("unreachable")
        }
    }

    // MARK: - Helpers

    /// Match a subscribed feed by full URL or host (same match as removeSource).
    static func matchItem(_ raw: String) throws -> SourceItem {
        guard let target = AppSourcesStore.shared.sources.first(where: {
            $0.url.absoluteString == raw || $0.url.host == raw
        }) else { throw ToolRouter.bail("no subscribed source matches \(raw)") }
        return target
    }

    /// Refresh one feed (by URL) or all feeds — headless twin of the Sources
    /// toolbar refresh (AppSourcesView). Cache sync, not data loss: no dryRun gate.
    static func refreshSources(_ args: [String: Any]) throws -> String {
        final class Box: @unchecked Sendable {
            var refreshed: [String] = []
        }
        let box = Box()
        let sema = DispatchSemaphore(value: 0)
        if let raw = args["url"] as? String, !raw.isEmpty {
            let target = try matchItem(raw)
            Task {
                await AppSourcesStore.shared.refreshSource(target)
                box.refreshed = [target.url.absoluteString]
                sema.signal()
            }
            sema.wait()
        } else {
            Task {
                await AppSourcesStore.shared.refreshAll()
                box.refreshed = AppSourcesStore.shared.sources.map { $0.url.absoluteString }
                sema.signal()
            }
            sema.wait()
        }
        return try ToolRouter.json(["refreshed": box.refreshed, "count": box.refreshed.count])
    }

    /// Rename a feed's display name. Destructive (mutates subscription): dryRun previews.
    // MARK: - Feed maintenance

    static func renameSource(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty,
              let name = args["name"] as? String else {
            throw ToolRouter.bail("url and name are required")
        }
        let target = try matchItem(raw)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "url": target.url.absoluteString, "name": name])
        }
        AppSourcesStore.shared.renameSource(target, to: name)
        return try ToolRouter.json(["url": target.url.absoluteString, "renamed": name])
    }

    /// Re-point a feed at a new URL (cache follows, old cache purged — same as the
    /// GUI edit sheet). Destructive: dryRun previews.
    static func editSourceURL(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty,
              let newURL = args["newUrl"] as? String, !newURL.isEmpty else {
            throw ToolRouter.bail("url and newUrl are required")
        }
        let target = try matchItem(raw)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "url": target.url.absoluteString, "newUrl": newURL])
        }
        final class Box: @unchecked Sendable {
            var error: String?
        }
        let box = Box()
        let sema = DispatchSemaphore(value: 0)
        Task {
            box.error = await AppSourcesStore.shared.updateSource(target, to: newURL)
            sema.signal()
        }
        sema.wait()
        if let err = box.error { throw ToolRouter.bail(err) }
        return try ToolRouter.json(["url": newURL, "updated": true])
    }

    /// Drop every custom source + caches + resume data (shipped empty state).
    /// Destructive: dryRun previews by default.
    static func resetSources(_ args: [String: Any]) throws -> String {
        let count = AppSourcesStore.shared.sources.count
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "wouldRemove": count])
        }
        AppSourcesStore.shared.resetAllSources()
        return try ToolRouter.json(["removed": count])
    }

    /// Pause / resume / cancel an in-flight feed download — headless twin of the
    /// transfer ring menu (SourceInstalls.pause/resume/cancel). Resume reuses the
    /// pinned or latest-compatible version like install_source_app. Destructive
    /// (cancel drops resume data): dryRun previews.
    static func sourceTransfer(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let action = args["action"] as? String,
              ["pause", "resume", "cancel"].contains(action) else {
            throw ToolRouter.bail("action is required: pause, resume, or cancel")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "action": action])
        }
        switch action {
        case "pause":
            SourceInstalls.shared.pause(bundleID: bid)
        case "resume":
            let version = args["version"] as? String
            let (_, picked) = try sourceApp(bundleID: bid, version: version)
            SourceInstalls.shared.resume(bundleID: bid, version: picked)
        default:
            SourceInstalls.shared.cancel(bundleID: bid)
        }
        return try ToolRouter.json(["bundleID": bid, "action": action,
                             "state": String(describing: SourceInstalls.shared.state(for: bid))])
    }

    /// Headless mirror of the Sources window search (AppSourcesView.filteredApps):
    /// substring match across name, bundleIdentifier, developerName, one row per
    /// app (bundleID-merged). Read-only; the GUI filter never had an MCP twin.
    // MARK: - Search and settle

    static func searchSourceApps(_ args: [String: Any]) throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolRouter.bail("query is required")
        }
        let q = query.lowercased()
        var hits: [[String: Any]] = []
        for item in AppSourcesStore.shared.sources {
            guard let source = item.source else { continue }
            for app in source.apps {
                guard app.name.lowercased().contains(q)
                    || app.bundleIdentifier.lowercased().contains(q)
                    || (app.developerName?.lowercased().contains(q) ?? false) else { continue }
                if hits.contains(where: { ($0["bundleID"] as? String) == app.bundleIdentifier }) { continue }
                hits.append([
                    "name": app.name,
                    "bundleID": app.bundleIdentifier,
                    "developer": app.developerName ?? "",
                    "source": item.url.absoluteString,
                    "versions": app.versions.map { $0.version },
                ])
            }
        }
        return try ToolRouter.json(["query": query, "count": hits.count, "apps": hits])
    }

    static func sourceApp(bundleID bid: String, version: String?) throws
        -> (app: SourceApp, picked: SourceAppVersion) {
        for item in AppSourcesStore.shared.sources {
            guard let source = item.source else { continue }
            for app in source.apps where app.bundleIdentifier == bid {
                if let version, !version.isEmpty {
                    if let match = app.versions.first(where: { $0.version == version }) {
                        return (app, match)
                    }
                } else if let latest = SourceInstalls.shared.latestCompatible(app) {
                    return (app, latest)
                }
            }
        }
        throw ToolRouter.bail(version == nil
            ? "no source lists \(bid)"
            : "no source lists \(bid) at version \(version ?? "")")
    }

    /// Wait until a source transfer leaves its active states, bounded.
    static func awaitSourceIdle(bundleID bid: String, timeout: TimeInterval) throws -> SourceInstallState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch SourceInstalls.shared.state(for: bid) {
            case .downloading, .installing:
                Thread.sleep(forTimeInterval: 1)
            case .paused, .idle, .failed:
                return SourceInstalls.shared.state(for: bid)
            }
        }
        throw ToolRouter.bail("install still in flight for \(bid) - check list_apps later")
    }
}
