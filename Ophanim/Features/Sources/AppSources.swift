//
//  AppSources.swift
//  Ophanim
//
//  App-source feeds for browsing and importing IPAs: the window lists downloadable apps
//  from user-added source URLs and installs them through the same Installer pipeline as
//  the import-IPA button. Each open re-fetches every source; the last good fetch is
//  cached per URL so the list still renders offline.
//
//  Feed shape is the community AltStore-format JSON (name + apps[] with versioned
//  download URLs, relative URLs resolved against the feed). Only the field names are
//  shared with that format - the loader below is ours. Malformed entries are skipped,
//  never fatal: a feed with no name or no usable apps fails stated at add time.
//

import Foundation
import CryptoKit

/// One downloadable build of a source app.
struct SourceAppVersion {
    let version: String
    let buildVersion: String?
    let downloadURL: URL
    let size: Int64?
    let date: String?
    let changelog: String?
    let minOSVersion: String?
    let maxOSVersion: String?
}

/// One news/comment entry from a feed ("comments" source for apps).
struct SourceNews: Identifiable {
    let id: String
    let title: String
    let caption: String?
    let date: String?
    let appID: String?
    let url: URL?
}

/// One app listed by a source feed.
struct SourceApp: Identifiable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let versions: [SourceAppVersion]
    let latestVersion: SourceAppVersion?
    let isBeta: Bool
}

/// One decoded feed.
struct AppSource {
    let name: String
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let website: URL?
    let apps: [SourceApp]
    let news: [SourceNews]
}

// MARK: - Feed decoding (lenient: every field optional except the load-bearing ones)

private struct SourceFeedResponse: Decodable {
    let name: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let website: String?
    let apps: [SourceFeedAppResponse]?
    let news: [SourceFeedNewsResponse]?
}

private struct SourceFeedAppResponse: Decodable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let screenshotURLs: [String]?
    let versions: [SourceFeedVersionResponse]?
}

private struct SourceFeedVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let minOSVersion: String?
    let maxOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case date
        case localizedDescription
        case downloadURL
        case size
        case minOSVersion
        case maxOSVersion
        // Spec key is `buildVersion` (live feeds); some feeds write `buildNumber`.
        case buildVersion
        case buildNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        // Prefer the spec key; fall back to the legacy alias.
        let specBuild = try c.decodeIfPresent(String.self, forKey: .buildVersion)
        let legacyBuild = try c.decodeIfPresent(String.self, forKey: .buildNumber)
        buildVersion = specBuild ?? legacyBuild
        date = try c.decodeIfPresent(String.self, forKey: .date)
        localizedDescription = try c.decodeIfPresent(String.self, forKey: .localizedDescription)
        downloadURL = try c.decodeIfPresent(String.self, forKey: .downloadURL)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        minOSVersion = try c.decodeIfPresent(String.self, forKey: .minOSVersion)
        maxOSVersion = try c.decodeIfPresent(String.self, forKey: .maxOSVersion)
    }
}

private struct SourceFeedNewsResponse: Decodable {
    let identifier: String?
    let title: String?
    let caption: String?
    let date: String?
    let tintColor: String?
    let imageURL: String?
    let url: String?
    let appID: String?
}

/// Fetches and decodes a feed: HTTP-status-checked download plus lenient decode
/// (malformed apps/news skip, never fail the feed; a nameless feed fails at add).
enum AppSourceLoader {
    /// Downloads a feed and returns the decoded source plus raw bytes (for caching).
    ///
    /// - Parameter url: The feed URL.
    /// - Returns: The decoded source and the raw feed data.
    /// - Throws: Network/HTTP errors or decode failures (nameless feed, bad JSON).
    static func load(from url: URL) async throws -> (AppSource, Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return (try decode(from: data, baseURL: url), data)
    }

    /// Decodes feed JSON against a base URL (relative download/icon URLs resolve
    /// against the feed location).
    ///
    /// - Parameter data: The raw feed JSON.
    /// - Parameter baseURL: The feed URL for relative resolution.
    /// - Returns: The decoded source.
    /// - Throws: Decoding errors (nameless feed) or malformed JSON.
    static func decode(from data: Data, baseURL: URL) throws -> AppSource {
        let response = try JSONDecoder().decode(SourceFeedResponse.self, from: data)
        guard let name = response.name, !name.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "source feed has no name"))
        }
        let apps = (response.apps ?? []).compactMap { buildApp(from: $0, baseURL: baseURL) }
        let news = (response.news ?? []).compactMap { n -> SourceNews? in
            guard let title = n.title, !title.isEmpty else { return nil }
            return SourceNews(id: n.identifier ?? "\(title)-\(n.date ?? "")",
                              title: title, caption: n.caption, date: n.date,
                              appID: n.appID,
                              url: absoluteURL(n.url, baseURL: baseURL))
        }
        return AppSource(name: name,
                         subtitle: response.subtitle,
                         description: response.description,
                         iconURL: absoluteURL(response.iconURL, baseURL: baseURL),
                         website: absoluteURL(response.website, baseURL: baseURL),
                         apps: apps,
                         news: news)
    }

    private static func buildApp(from response: SourceFeedAppResponse,
                                 baseURL: URL) -> SourceApp? {
        guard let name = response.name, !name.isEmpty,
              let bundleIdentifier = response.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        let versions = (response.versions ?? []).compactMap { v -> SourceAppVersion? in
            guard let version = v.version,
                  let raw = v.downloadURL,
                  let downloadURL = absoluteURL(raw, baseURL: baseURL) else { return nil }
            return SourceAppVersion(version: version, buildVersion: v.buildVersion,
                                    downloadURL: downloadURL, size: v.size,
                                    date: v.date, changelog: v.localizedDescription,
                                    minOSVersion: v.minOSVersion, maxOSVersion: v.maxOSVersion)
        }
        // Legacy flat shape (version + downloadURL at the app level) when versions[] is absent.
        let legacy: SourceAppVersion? = {
            guard versions.isEmpty,
                  let version = response.version,
                  let raw = response.downloadURL,
                  let downloadURL = absoluteURL(raw, baseURL: baseURL) else { return nil }
            return SourceAppVersion(version: version, buildVersion: nil,
                                    downloadURL: downloadURL, size: nil,
                                    date: response.versionDate, changelog: nil,
                                    minOSVersion: nil, maxOSVersion: nil)
        }()
        let latest = versions.first ?? legacy
        return SourceApp(name: name,
                         bundleIdentifier: bundleIdentifier,
                         developerName: response.developerName,
                         subtitle: response.subtitle,
                         description: response.localizedDescription ?? response.versionDescription,
                         iconURL: absoluteURL(response.iconURL, baseURL: baseURL),
                         versions: versions,
                         latestVersion: latest,
                         isBeta: response.beta ?? false)
    }

    /// Absolute URLs pass through; relative ones resolve against the feed URL (feeds that
    /// host icons next to the JSON use bare paths).
    private static func absoluteURL(_ string: String?, baseURL: URL) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        if let absolute = URL(string: string), absolute.scheme != nil { return absolute }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - Store

/// One subscribed feed: its URL (identity), an optional display alias, last decoded
/// state, and fetch status.
struct SourceItem: Identifiable {
    var url: URL
    var id: URL { url }
    var customName: String?
    var source: AppSource?
    var isLoading: Bool
    var error: String?

    init(url: URL, isLoading: Bool = false, source: AppSource? = nil,
         error: String? = nil, customName: String? = nil) {
        self.url = url
        self.customName = customName
        self.source = source
        self.isLoading = isLoading
        self.error = error
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let source { return source.name }
        if let host = url.host, !host.isEmpty { return host }
        return url.absoluteString
    }

    fileprivate var record: SourceRecord {
        SourceRecord(url: url.absoluteString, customName: customName)
    }
}

/// Persisted shape (v2: url + alias). v1 was a bare string array - still read.
private struct SourceRecord: Codable {
    var url: String
    var customName: String?
}

/// Owns the subscribed-source list, its persistence, the per-URL fetch cache, and the
/// in-flight download/install set. URLs persist as a JSON string array under the
/// product container (global config, not per-app: uninstalling an app must not drop the
/// user's feeds). One cache file per URL, rewritten on each good fetch and deleted with
/// its source - plus an orphan sweep on load, so removed feeds leave nothing behind.
@Observable
final class AppSourcesStore: @unchecked Sendable {
    static let shared = AppSourcesStore()

    private(set) var sources: [SourceItem] = []
    private(set) var isRefreshingAll = false

    private var storeDir: URL {
        Galgal.ophanimContainer.appendingPathComponent("AppSources")
    }
    private var listURL: URL { storeDir.appendingPathComponent("sources.json") }
    private var cacheDir: URL { storeDir.appendingPathComponent("Cache") }

    init() {
        loadStoredSources()
        Task { await refreshAll() }
    }

    // MARK: - Sources

    /// Returns a localized error message, or nil on success.
    func addSource(from rawValue: String) async -> String? {
        guard let url = normalizeURL(from: rawValue) else {
            return NSLocalizedString("sources.error.invalidURL", comment: "")
        }
        if sources.contains(where: { $0.url == url }) {
            return NSLocalizedString("sources.error.duplicate", comment: "")
        }
        sources.append(SourceItem(url: url, isLoading: true))
        persistSources()
        await refreshSource(url: url)
        // A feed that fails still leaves its row: the error renders inline with a retry,
        // exactly like a fetch that breaks later. Nothing to show is a state, not a loss.
        return nil
    }

    /// Removes a feed, its cache, and its row (in-flight refresh for it no-ops).
    ///
    /// - Parameter item: The subscribed feed to remove.
    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        persistSources()
        removeCache(for: item.url)
    }

    /// Edit a source's URL in place (stated error on bad URL or duplicate).
    /// Cache follows the new URL; the old cache is purged.
    func updateSource(_ item: SourceItem, to rawValue: String) async -> String? {
        guard let url = normalizeURL(from: rawValue) else {
            return NSLocalizedString("sources.error.invalidURL", comment: "")
        }
        if url != item.url, sources.contains(where: { $0.url == url }) {
            return NSLocalizedString("sources.error.duplicate", comment: "")
        }
        guard let index = sources.firstIndex(where: { $0.id == item.id }) else { return nil }
        let oldURL = sources[index].url
        sources[index].url = url
        sources[index].source = nil
        persistSources()
        removeCache(for: oldURL)
        await refreshSource(url: url)
        return nil
    }

    /// Renames a feed's display alias only (no fetch; empty clears the alias).
    ///
    /// - Parameter item: The subscribed feed to rename.
    /// - Parameter name: The new alias (empty clears it).
    func renameSource(_ item: SourceItem, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sources[index].customName = trimmed.isEmpty ? nil : trimmed
        persistSources()
    }

    /// Reset: drop every custom source, its cache, and any persisted download-resume
    /// data. There is no bundled default set - reset returns to the shipped empty
    /// state, stated, not a re-added feed list.
    func resetAllSources() {
        sources = []
        persistSources()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: Galgal.ophanimContainer
            .appendingPathComponent("AppSources/Resume"))
    }

    /// Re-fetches one feed by row (error renders inline; last-good state stays).
    ///
    /// - Parameter item: The subscribed feed to refresh.
    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
    }

    /// Re-fetches every feed in order (no-op when none are subscribed).
    func refreshAll() async {
        guard !sources.isEmpty else { return }
        isRefreshingAll = true
        for url in sources.map(\.url) {
            await refreshSource(url: url)
        }
        isRefreshingAll = false
    }

    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else { return }
        sources[index].isLoading = true
        sources[index].error = nil
        do {
            let (source, data) = try await AppSourceLoader.load(from: url)
            guard let at = sources.firstIndex(where: { $0.url == url }) else { return }
            sources[at].source = source
            sources[at].isLoading = false
            storeCache(data, for: url)
        } catch {
            guard let at = sources.firstIndex(where: { $0.url == url }) else { return }
            sources[at].error = error.localizedDescription
            sources[at].isLoading = false
        }
    }

    // MARK: - Persistence + cache

    private func loadStoredSources() {
        try? FileManager.default.createDirectory(at: storeDir,
                                                 withIntermediateDirectories: true)
        // v2 records first, v1 bare-string array as fallback (pre-alias installs).
        let records: [SourceRecord]
        if let data = try? Data(contentsOf: listURL),
           let v2 = try? JSONDecoder().decode([SourceRecord].self, from: data) {
            records = v2
        } else {
            let stored = ((try? Data(contentsOf: listURL))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
            records = stored.map { SourceRecord(url: $0, customName: nil) }
        }
        let urls = records.compactMap { URL(string: $0.url) }
        sources = urls.compactMap { url in
            let customName = records.first(where: { $0.url == url.absoluteString })?.customName
            return SourceItem(url: url, customName: customName)
        }
        for index in sources.indices {
            let url = sources[index].url
            if let data = cachedData(for: url),
               let cached = try? AppSourceLoader.decode(from: data, baseURL: url) {
                sources[index].source = cached
            }
        }
        sweepOrphanCaches(keeping: Set(urls))
    }

    private func persistSources() {
        let data = try? JSONEncoder().encode(sources.map { $0.record })
        try? data?.write(to: listURL, options: .atomic)
    }

    private func cacheFileURL(for url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
        let hex = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hex).json")
    }

    private func cachedData(for url: URL) -> Data? {
        guard let file = cacheFileURL(for: url) else { return nil }
        return try? Data(contentsOf: file)
    }

    private func storeCache(_ data: Data, for url: URL) {
        guard let file = cacheFileURL(for: url) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func removeCache(for url: URL) {
        guard let file = cacheFileURL(for: url) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Cache files whose source is gone (removed while a write raced, or hand-deleted
    /// lists): enumerated by filename, so a removed feed leaves nothing behind.
    private func sweepOrphanCaches(keeping urls: Set<URL>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else { return }
        let wanted = Set(urls.map { cacheFileName(for: $0) })
        for entry in entries where entry.pathExtension == "json"
            && !wanted.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func cacheFileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Accepts absolute URLs, file paths, and bare hosts (https assumed); trims.
    ///
    /// - Parameter rawValue: The user-typed source location.
    /// - Returns: The normalized URL, or nil when empty.
    private func normalizeURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }
}
