//
//  OPCrashCorrelator.swift
//  Ophanim (host-only: needs DiagnosticReports visibility + OPPaths)
//
//  Previous-run crash summary, computed at launch BEFORE the sweep destroys evidence.
//  Writes (or refreshes) one file per app - Logs/<bid>/last-crash.json - so the single
//  previous run's explanation survives clearPreviousRuns (which deletes run files with
//  their crash files) while history still cannot accumulate: one file, rewritten.
//
//  Honesty rules: a previous run with an NDJSON log but no crash artifact is reported as
//  "no-crash-file" (clean quit and silent kill are indistinguishable - stated, never
//  guessed). kill-silent is NEVER auto-written; it appears only as that explicit absence.
//  OS reports are referenced by path when their mtime falls in the run window, never
//  parsed for PII beyond existence.
//

import Foundation

struct OPLastCrash: Codable {
    var runId: String = ""
    var ndjsonEvents: Int = 0
    var hasCrashFile: Bool = false
    var kind: String? = nil
    var crashFile: String? = nil
    var osReports: [String] = []
    var note: String = ""
}

enum OPCrashCorrelator {
    static func fileURL(bundleID: String) -> URL {
        OPPaths.logDirectory(forBundleID: bundleID).appendingPathComponent("last-crash.json")
    }

    /// Summarize the previous run into last-crash.json. Call at launch, before any sweep.
    /// Silent on failure (a missing summary is itself "no evidence").
    static func summarizePreviousRun(bundleID: String) {
        let dir = OPPaths.logDirectory(forBundleID: bundleID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let runs = entries.filter {
            $0.pathExtension == "ndjson"
                && $0.deletingPathExtension().lastPathComponent.hasPrefix("run-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let latest = runs.last else { return } // no previous run: nothing to say
        var summary = OPLastCrash()
        summary.ndjsonEvents = countLines(latest)
        let crashes = OPCrashWriter.records(in: dir)
        if let newest = crashes.last {
            summary.runId = newest.runId
            summary.hasCrashFile = true
            summary.kind = newest.kind.rawValue
            summary.crashFile = newest.runId.isEmpty ? nil
                : "run-\(newest.runId).crashreason.json"
            summary.note = "guest-recorded \(newest.kind.rawValue)"
        } else {
            summary.runId = runIdFromLog(latest) ?? latest.deletingPathExtension().lastPathComponent
            summary.note = "no crash artifact: clean quit or silent kill (indistinguishable)"
        }
        summary.osReports = matchingOSReports(bundleID: bundleID, runFile: latest)
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: fileURL(bundleID: bundleID), options: .atomic)
        }
    }

    static func load(bundleID: String) -> OPLastCrash? {
        guard let data = try? Data(contentsOf: fileURL(bundleID: bundleID)),
              let summary = try? JSONDecoder().decode(OPLastCrash.self, from: data) else { return nil }
        return summary
    }

    /// Run identity from the ophanim.start event (carries runId+pid); nil when absent.
    /// The start event is the first write of every run, but the scan doesn't assume it:
    /// it checks leading lines for the marker instead of blindly parsing line one.
    private static func runIdFromLog(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data.prefix(65536), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(5) {
            guard line.contains("ophanim.start"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let fields = json["fields"] as? [String: String],
                  let runId = fields["runId"], !runId.isEmpty else { continue }
            return runId
        }
        return nil
    }

    private static func countLines(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    /// OS crash reports for this bundle id modified since the run file (run window).
    /// Referenced by path only - never parsed. Absent DiagnosticReports dir = no evidence,
    /// not evidence of absence (directory absence is stated by omission: empty list).
    private static func matchingOSReports(bundleID: String, runFile: URL) -> [String] {
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                    home.appendingPathComponent("Library/Logs/CrashReporter/DiagnosticLogs")]
        guard let runMtime = (try? runFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return [] }
        var out: [String] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in entries where f.lastPathComponent.contains(bundleID) {
                if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, m >= runMtime {
                    out.append(f.path)
                }
            }
        }
        return out.sorted()
    }
}
