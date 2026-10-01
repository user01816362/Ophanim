import Foundation

/// App-Sources tools: list/add/remove feeds, install a feed app (optionally
/// pinned to a version). The stores are synchronous, so handlers call them
/// directly; only the async fetch and the install settle loop need bridging.
enum SourceTools {
    static func listSources(_ args: [String: Any]) throws -> String {
        let feeds: [[String: Any]] = AppSourcesStore.shared.sources.map { item in
            var d: [String: Any] = [
                "url": item.url.absoluteString,
                "displayName": item.displayName,
                "appCount": item.source?.apps.count ?? 0,
            ]
            if item.isLoading { d["loading"] = true }
            if let error = item.error { d["error"] = error }
            if let news = item.source?.news, !news.isEmpty {
                d["news"] = news.map { ["title": $0.title, "caption": $0.caption ?? ""] }
            }
            return d
        }
        return try ToolRouter.json(["count": feeds.count, "sources": feeds])
    }

    static func addSource(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw ToolRouter.bail("url is required") }
        var addError: String?
        let sema = DispatchSemaphore(value: 0)
        Task {
            addError = await AppSourcesStore.shared.addSource(from: raw)
            sema.signal()
        }
        sema.wait()
        if let addError { throw ToolRouter.bail(addError) }
        return try ToolRouter.json(["subscribed": raw])
    }

    static func removeSource(_ args: [String: Any]) throws -> String {
        guard let raw = args["url"] as? String, !raw.isEmpty else { throw ToolRouter.bail("url is required") }
        guard let target = AppSourcesStore.shared.sources.first(where: {
            $0.url.absoluteString == raw || $0.url.host == raw
        }) else { throw ToolRouter.bail("no subscribed source matches \(raw)") }
        AppSourcesStore.shared.removeSource(target)
        return try ToolRouter.json(["removed": target.url.absoluteString])
    }

    static func installSourceApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let version = args["version"] as? String
        let (app, picked) = try sourceApp(bundleID: bid, version: version)
        SourceInstalls.shared.start(app: app, version: picked)
        switch try awaitSourceIdle(bundleID: bid, timeout: 600) {
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
