//
//  OPLogSink.swift
//  OphanimCore
//
//  Pluggable, combinable log sinks: NDJSON file, plain-text file, os_log. All writes go through
//  a single serial queue off the caller's thread so instrumentation never blocks the target app.
//

import Foundation
import os

/// A destination for events.
///
/// Guest-only: sinks run in the injected agent, never in the host app.
public protocol OPLogSink: AnyObject {
    func write(_ event: OPEvent)
    func flush()
}

/// Fan-out to multiple sinks behind one serial queue.
///
/// - Parameter event: Event to write (redacted per sink config first).
public final class OPSinkMultiplexer: @unchecked Sendable {
    private let sinks: [OPLogSink]
    private let queue = DispatchQueue(label: "be.ophanim.sink", qos: .utility)

    public init(_ sinks: [OPLogSink]) { self.sinks = sinks }

    public func emit(_ event: OPEvent) {
        queue.async { [sinks] in
            // Sink writes do file I/O / os_log, which would re-trigger the filesystem hooks.
            // Suppress instrumentation on this thread while writing.
            OPReentry.guarded {
                for s in sinks { s.write(event) }
            }
        }
    }

    /// Flushes every sink synchronously on the multiplexer queue.
    public func flush() {
        queue.sync { for s in sinks { s.flush() } }
    }

    /// Builds the active sink set from config, resolving the log directory.
    ///
    /// - Parameter config: Active agent config (selects sinks + redaction keys).
    /// - Parameter logDirectory: Directory the file sinks write into (created if missing).
    /// - Returns: Multiplexer over the enabled sinks.
    public static func make(config: OPConfig, logDirectory: URL) -> OPSinkMultiplexer {
        var sinks: [OPLogSink] = []
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stamp = OPFileSink.runStamp()
        if config.sinks.contains(.ndjson) {
            sinks.append(OPFileSink(url: logDirectory.appendingPathComponent("run-\(stamp).ndjson"),
                                    format: .ndjson, redactionKeys: config.redactionKeys))
        }
        if config.sinks.contains(.plainText) {
            sinks.append(OPFileSink(url: logDirectory.appendingPathComponent("run-\(stamp).log"),
                                    format: .plainText, redactionKeys: config.redactionKeys))
        }
        if config.sinks.contains(.osLog) {
            sinks.append(OPOsLogSink(redactionKeys: config.redactionKeys))
        }
        return OPSinkMultiplexer(sinks)
    }
}

/// Applies redaction to an event's sensitive fields before it is written.
private func redacted(_ event: OPEvent, keys: [String]) -> OPEvent {
    guard !keys.isEmpty else { return event }
    let lower = Set(keys.map { $0.lowercased() })
    var e = event
    e.fields = e.fields.mapValues { $0 }
    for k in e.fields.keys where lower.contains(k.lowercased()) {
        e.fields[k] = "‹redacted›"
    }
    return e
}

/// File sink supporting NDJSON or flat plain-text, append-only.
public final class OPFileSink: OPLogSink {
    public enum Format { case ndjson, plainText }

    private let handle: FileHandle?
    private let format: Format
    private let redactionKeys: [String]
    private let encoder: JSONEncoder
    private let iso = ISO8601DateFormatter()

    /// Opens (or creates) the append-only log file and seeks to its end.
    ///
    /// - Parameter url: File to append to.
    /// - Parameter format: NDJSON or plain-text line format.
    /// - Parameter redactionKeys: Field names replaced with ‹redacted› before writing.
    public init(url: URL, format: Format, redactionKeys: [String]) {
        self.format = format
        self.redactionKeys = redactionKeys
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Append-only: only create the file if it's absent (createFile truncates an existing file),
        // then seek to the end. This matters for config live-reload, which rebuilds the sink set and
        // reopens this same per-launch file - truncating it would discard the run's events so far.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        self.handle = h
    }

    /// Encodes one event (redacted) and appends it as a single line.
    ///
    /// - Parameter event: Event to write.
    public func write(_ event: OPEvent) {
        let e = redacted(event, keys: redactionKeys)
        let line: Data
        switch format {
        case .ndjson:
            guard var data = try? encoder.encode(e) else { return }
            data.append(0x0A)
            line = data
        case .plainText:
            line = (e.plainTextLine(iso: iso) + "\n").data(using: .utf8) ?? Data()
        }
        try? handle?.write(contentsOf: line)
    }

    public func flush() { try? handle?.synchronize() }

    /// One stamp per process launch, cached. Config live-reload rebuilds the sink set on every config
    /// change; without caching, each rebuild would mint a new run-<stamp>.{ndjson,log} and fragment a
    /// single run's capture across many files. Caching makes every rebuild reopen and append to the
    /// same per-launch file. (A fresh process launch re-initializes this, so each run still gets its
    /// own file.)
    private static let cachedRunStamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }()

    static func runStamp() -> String { cachedRunStamp }
}

/// Emits via os_log under the be.ophanim subsystem so events appear in Console.app / `log stream`.
public final class OPOsLogSink: OPLogSink {
    private let redactionKeys: [String]
    private let iso = ISO8601DateFormatter()
    private let loggers: [OPCategory: Logger]

    /// Stands up one os_log logger per capture category.
    ///
    /// - Parameter redactionKeys: Field names replaced with ‹redacted› before writing.
    public init(redactionKeys: [String]) {
        self.redactionKeys = redactionKeys
        var map: [OPCategory: Logger] = [:]
        for c in OPCategory.allCases {
            map[c] = Logger(subsystem: "be.ophanim", category: c.rawValue)
        }
        self.loggers = map
    }

    /// Logs one redacted event line to its category logger.
    ///
    /// - Parameter event: Event to write.
    public func write(_ event: OPEvent) {
        let e = redacted(event, keys: redactionKeys)
        let line = e.plainTextLine(iso: iso)
        loggers[e.category]?.log("\(line, privacy: .public)")
    }

    public func flush() {}
}
