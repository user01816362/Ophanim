//
//  BookmarkStore.swift
//  Ophanim
//
//  Agent bookmarks over Inspect findings: marks + comments + groups over runtime classes,
//  tree elements, and binary symbols, so an agent can annotate and re-analyze across MCP
//  calls. Reference-not-value throughout: bookmarks point at findings (names, ids,
//  timeline snapshot ids), never at tree/class-dump contents.
//
//  Separate per-app JSON store, NOT the settings plist: the plist has a documented
//  cross-process lost-update hazard (GUI blind overwrite vs MCP read-modify-write,
//  docs/audit/AUDIT-1-correctness.md) and is parsed at agent boot - annotation traffic
//  must not inflate or race launch-critical config. Uninstall removes this file with the
//  rest of per-app state (see Uninstaller.perAppState); clearing the app's data removes
//  it too (marks describe that data). Writes are atomic under a process-local lock;
//  cross-process races stay best-effort, confined to annotation data where a lost update
//  costs a comment, not a config.
//

import Foundation

/// What a bookmark points at. Class/symbol names are stable across launches; element ids
/// are positional index paths that die with their tree, so element bookmarks REQUIRE a
/// timeline snapshot ref and go stale when the tree moves on.
struct BookmarkTarget: Codable {
    var kind: String            // class | element | symbol
    var className: String?
    var elementId: String?
    var mode: String?
    var symbol: String?
    // Hints for the agent's display only; re-resolution is authoritative.
    var role: String?
    var frame: [Double]?
    var axLabel: String?
    var viewController: String?
    var superclasses: [String]?
}

/// One agent annotation: a stable finding reference plus comment/tags.
struct AgentBookmark: Codable {
    var id: String              // bm_<hex>
    var bundleID: String
    var target: BookmarkTarget
    var comment: String?
    var tags: [String]
    var createdAt: String
    var updatedAt: String
    var snapshotRef: String?
}

/// A named filing group over bookmark ids (members follow the bookmark).
struct BookmarkGroup: Codable {
    var id: String              // grp_<hex>
    var name: String
    var note: String?
    var bookmarkIds: [String]
    var createdAt: String
    var updatedAt: String
}

/// The per-app bookmark file schema (versioned for forward migration).
struct BookmarkStoreData: Codable {
    var version: Int
    var bookmarks: [AgentBookmark]
    var groups: [BookmarkGroup]
}

enum BookmarkStore {
    /// Hard bounds: bookmarks are O(findings) and an agent annotates constantly.
    /// Reference-not-value keeps each entry small, but count needs a ceiling so the
    /// file read whole on every call cannot grow without bound.
    static let maxBookmarks = 2000
    static let maxPins = 500

    /// Test seam: logic tests point the store at a temp dir without Galgal.
    nonisolated(unsafe) static var testRoot: URL? = nil

    /// Store root (test-overridable). Created on demand.
    ///
    /// - Returns: The `AgentBookmarks` directory URL.
    static func storeRoot() -> URL {
        let root = (testRoot ?? Galgal.ophanimContainer)
            .appendingPathComponent("AgentBookmarks")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Per-app bookmark file URL.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The store file URL (may not exist yet).
    static func fileURL(bundleID: String) -> URL {
        storeRoot().appendingPathComponent("\(bundleID).json")
    }

    /// Loads an app's bookmarks. Missing/corrupt files read as empty (never fatal).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The store data, or an empty store.
    static func load(bundleID: String) -> BookmarkStoreData {
        guard let data = try? Data(contentsOf: fileURL(bundleID: bundleID)),
              let store = try? JSONDecoder().decode(BookmarkStoreData.self, from: data) else {
            return BookmarkStoreData(version: 1, bookmarks: [], groups: [])
        }
        return store
    }

    private static let fileLock = NSLock()

    /// Read-modify-write under a process-local lock, committed atomically. Same posture
    /// as both existing writers (.atomic, no cross-process lock): a lost update costs a
    /// comment, and the alternative (a lock protocol) does not exist anywhere in the repo.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter body: The in-place mutation to commit.
    /// - Returns: The committed store data.
    @discardableResult
    static func modify(bundleID: String,
                       _ body: (inout BookmarkStoreData) throws -> Void) rethrows -> BookmarkStoreData {
        fileLock.lock()
        defer { fileLock.unlock() }
        var store = load(bundleID: bundleID)
        try body(&store)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL(bundleID: bundleID), options: .atomic)
        }
        return store
    }

    /// Snapshot ids pinned by any bookmark: these survive the launch sweep and the
    /// keep-N prune. Bounded by maxPins at pin time.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The pinned snapshot ids.
    static func snapshotRefs(bundleID: String) -> Set<String> {
        Set(load(bundleID: bundleID).bookmarks.compactMap(\.snapshotRef))
    }

    /// ISO-8601 timestamp for bookmark fields.
    ///
    /// - Parameter date: The date to stamp (default now).
    /// - Returns: The timestamp string.
    static func stamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Mints a prefixed random id (`bm_`/`grp_` + 8 hex chars).
    ///
    /// - Parameter prefix: The id prefix.
    /// - Returns: The fresh id.
    static func mintID(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    }
}
