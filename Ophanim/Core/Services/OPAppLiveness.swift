//
//  OPAppLiveness.swift
//  Ophanim (host-only: written by the GUI app, read by GUI + every --mcp child)
//
//  The single realtime liveness pipeline. The GUI app (the only long-lived observer)
//  marks launch/exit per hosted app; short-lived --mcp children (one per client
//  connection, arbitrary spawn contexts) read one file instead of trusting their own
//  LaunchServices view - a client-spawned child can see a different application list
//  than a shell-spawned one for the same running app (proven live: same binary,
//  shell spawn screenshotted 1280x720 while the client spawn refused "not running").
//
//  Schema: state-<bid>.json {pid, alive, at}. Latest mark wins. An `exited` mark is
//  authoritative (the GUI watched the death happen); an `alive` mark is trusted only
//  while fresh (180 s) and otherwise falls through to heartbeat/log evidence, so a
//  GUI restart without an exit mark can never claim "running" forever.
//

import Foundation

enum OPAppLiveness {
    private static func stateURL(bundleID bid: String) -> URL {
        OPPaths.logDirectory(forBundleID: bid).appendingPathComponent("state-\(bid).json")
    }

    private struct Mark: Codable {
        var pid: Int32
        var alive: Bool
        var at: Date
    }

    /// Marks a launch (pid-bound, so a stale exit cannot shadow a relaunch).
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Parameter pid: The launched process id.
    static func markLaunched(bundleID bid: String, pid: Int32) {
        write(bundleID: bid, mark: Mark(pid: pid, alive: true, at: Date()))
    }

    /// Record an exit only when it matches the currently recorded launch: a stale death
    /// (e.g. for a pid from before a relaunch) must never overwrite a newer alive mark.
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Parameter pid: The exiting process id (must match the recorded launch).
    static func markExited(bundleID bid: String, pid: Int32) {
        guard let current = read(bundleID: bid), current.pid == pid, current.alive else { return }
        write(bundleID: bid, mark: Mark(pid: pid, alive: false, at: Date()))
    }

    /// The authoritative verdict when one exists: false on a recorded exit, true on a
    /// fresh launch mark. Nil when there is no usable mark (never launched, or the GUI
    /// restarted without remarking) - callers fall through to heartbeat/log evidence.
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Returns: The verdict, or nil when no mark decides.
    static func authoritativeState(bundleID bid: String) -> Bool? {
        guard let current = read(bundleID: bid) else { return nil }
        // Defense in depth: marks with impossible pids (written before the
        // write-side guard) never decide anything - fall through to evidence.
        guard current.pid > 0 else { return nil }
        if !current.alive { return false }
        guard Date().timeIntervalSince(current.at) < MCPTimeouts.stateFresh else { return nil }
        return true
    }

    private static func read(bundleID bid: String) -> Mark? {
        guard let data = try? Data(contentsOf: stateURL(bundleID: bid)),
              let mark = try? JSONDecoder().decode(Mark.self, from: data) else { return nil }
        return mark
    }

    private static func write(bundleID bid: String, mark: Mark) {
        let url = stateURL(bundleID: bid)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(mark) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
