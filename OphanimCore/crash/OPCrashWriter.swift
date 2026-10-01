//
//  OPCrashWriter.swift
//  OphanimCore (shared: guest engine + host app)
//
//  The single write/read/retention path for crash-cause artifacts. Files live alongside
//  the NDJSON they explain - `run-<stamp>-<pid>.crashreason.json` next to
//  `run-<stamp>.ndjson` - so retention, uninstall purge, and per-run pairing fall out of
//  the existing log-dir contract instead of inventing a second store. Takes an explicit
//  directory (never a bundle id): the guest resolves it once at attach, the host resolves
//  it per call; neither side re-derives the other's paths.
//

import Foundation

public enum OPCrashWriter {
    /// run-<stamp>.ndjson  ->  run-<stamp>-<pid>.crashreason.json. Lexical order is
    /// chronological, same as run files (keep/prune rely on it).
    public static func fileURL(stamp: String, pid: Int, in dir: URL) -> URL {
        dir.appendingPathComponent("run-\(stamp)-\(pid).crashreason.json")
    }

    public static func isCrashFile(_ url: URL) -> Bool {
        url.pathExtension == "json"
            && url.deletingPathExtension().lastPathComponent.hasPrefix("run-")
            && url.lastPathComponent.hasSuffix(".crashreason.json")
    }

    /// Atomic write; silent on failure (a crash writer that throws is a second crash).
    /// Returns the file URL on success for chaining.
    @discardableResult
    public static func write(_ record: OPCrashRecord, stamp: String, pid: Int, in dir: URL) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(stamp: stamp, pid: pid, in: dir)
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// All decodable records, oldest first. Undecodable files are skipped, never fatal.
    public static func records(in dir: URL) -> [OPCrashRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [OPCrashRecord] = []
        for f in entries.filter(isCrashFile)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: f),
                  let record = try? JSONDecoder().decode(OPCrashRecord.self, from: data) else { continue }
            out.append(record)
        }
        return out
    }

    /// Delete every crash file (launch sweep). Host-side files alongside guest-written
    /// ones share the namespace; the guest never depends on their presence.
    @discardableResult
    public static func sweep(in dir: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for f in entries.filter(isCrashFile) {
            if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }

    /// Keep the newest `keep` crash files (pairs with pruneRuns keep-N on the NDJSON side).
    public static func prune(in dir: URL, keep: Int = 3) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        let files = entries.filter(isCrashFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > keep else { return }
        for stale in files.dropLast(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
