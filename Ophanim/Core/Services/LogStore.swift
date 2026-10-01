//
//  LogStore.swift
//  Ophanim
//
//  One home for capture-log retention: every deleter below agrees on what a "run file" is
//  (run-<stamp>.ndjson/.log in the canonical log dir), so the viewer, the launch sweep, and
//  MCP cannot disagree about what gets deleted. Live file safety comes from ordering, not
//  locking: both entry points run when no writer holds the files (viewer open, pre-launch),
//  plus an isRunning guard on the launch path.
//

import Foundation

extension Notification.Name {
    /// Posted after LogStore deletes an app's run files out from under readers, so an open
    /// viewer resets its in-memory events and offsets instead of merging stale with new.
    /// object carries the bundle identifier.
    static let ophanimLogsCleared = Notification.Name("be.ophanim.Ophanim.logsCleared")
}

enum LogStore {
    /// Directories that hold an app's run files. Canonical first (the only writer), legacy
    /// second (read for pre-fix history). Inspect protocol files cohabit the canonical dir
    /// and are never run files - every function here filters by name, not just extension.
    static func runDirectories(bundleID: String) -> [URL] {
        [OPPaths.logDirectory(forBundleID: bundleID),
         OPPaths.legacyLogDirectory(forBundleID: bundleID)]
    }

    static func runFiles(bundleID: String) -> [URL] {
        var out: [URL] = []
        for dir in runDirectories(bundleID: bundleID) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            out += entries.filter {
                $0.pathExtension == "ndjson" || $0.pathExtension == "log"
            }.filter {
                $0.deletingPathExtension().lastPathComponent.hasPrefix("run-")
            }
        }
        // Lexical order is chronological (run-<stamp>); newest last.
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keep the newest `keep` run files, delete the rest. The active run is always newest,
    /// so the file being written is never touched. Silent on failure: worst case the
    /// directory stays untidied and readers cope anyway. Crash-cause files prune alongside
    /// (same keep-N, same silence) so a run's explanation never outlives its log.
    static func pruneRuns(bundleID: String, keep: Int = 3) {
        let runs = runFiles(bundleID: bundleID)
        guard runs.count > keep else { return }
        for stale in runs.dropLast(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
        for dir in runDirectories(bundleID: bundleID) {
            OPCrashWriter.prune(in: dir, keep: keep)
        }
    }

    /// Delete ALL previous run files, for a fresh log on launch. Must run before the engine
    /// mints the new stamp file, and never while the app runs (an instance still alive from
    /// before holds the newest files open - deleting those orphans the writer). Returns
    /// false when skipped, so callers can state it instead of claiming a fresh log.
    @discardableResult
    static func clearPreviousRuns(bundleID: String) -> Bool {
        guard !ContainerProfiles.isRunning(bundleID: bundleID) else { return false }
        var removed = false
        for stale in runFiles(bundleID: bundleID) {
            if (try? FileManager.default.removeItem(at: stale)) != nil {
                removed = true
            }
        }
        for dir in runDirectories(bundleID: bundleID) {
            if OPCrashWriter.sweep(in: dir) > 0 { removed = true }
        }
        if removed {
            NotificationCenter.default.post(name: .ophanimLogsCleared, object: bundleID)
        }
        return removed
    }
}
