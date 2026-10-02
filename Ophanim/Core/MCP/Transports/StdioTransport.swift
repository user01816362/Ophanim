//
//  StdioTransport.swift
//  Ophanim
//
//  Headless `--mcp` stdio transport: newline-delimited JSON-RPC over
//  stdin/stdout, one child per client. Shared state is file-backed.
//

import Foundation
import Darwin

// MARK: - stdio transport (headless `--mcp`)

/// stdio transport (headless `--mcp`): newline-delimited JSON-RPC over
/// stdin/stdout, one child per connected client. Shared state is file-backed
/// (settings plists, NDJSON logs, inspect slot); in-memory state does not
/// cross children.
enum MCPStdioTransport {
    /// Serializes stdout writes: the request loop below and the event-notifier
    /// thread share one pipe, and concurrent FileHandle writes would interleave bytes.
    static let writeLock = NSLock()
    /// Set once the run loop owns stdout. Subscribe tools refuse when false (HTTP/GUI
    /// process): push belongs to the stdio child that owns the pipe. Written once
    /// before the loop starts, read thereafter.
    nonisolated(unsafe) private(set) static var notifierActive = false

    /// One locked line write (response or notification).
    ///
    /// - Parameter data: The JSON bytes (newline appended by the transport).
    static func writeLine(_ data: Data) {
        writeLock.lock()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        writeLock.unlock()
    }

    /// Blocking newline-delimited JSON-RPC loop over stdin/stdout. Never returns.
    ///
    /// Exits with usage guidance when launched interactively (both stdio ends
    /// are TTYs): a real client always holds our stdout as a pipe, so the TTY
    /// check never trips a client. Malformed lines are skipped, notifications
    /// get no reply.
    ///
    /// - Returns: Never.
    static func run() -> Never {
        // stdio mode is meant to be spawned by an MCP client that drives requests over the stdin
        // pipe. Launched interactively (a terminal, or double-clicking the app) stdin is a TTY with
        // no client, so the read loop would hit EOF instantly and exit "for no reason". Detect that
        // and explain how to run a standalone server instead of exiting silently.
        // Require BOTH stdin and stdout to be TTYs: that's a real interactive terminal. A client
        // always reads our stdout (a pipe), so this never trips a client - even one that hands us a
        // pty for stdin.
        if isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 {
            FileHandle.standardError.write(Data(
                ("ophanim: --mcp stdio mode expects an MCP client to drive it over stdin.\n" +
                 "         To run a standalone server, use:  Ophanim --mcp --http [--port N]\n").utf8))
            exit(0)
        }
        let out = FileHandle.standardOutput
        let newline = Data([0x0a])
        notifierActive = true
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let response = MCPServer.shared.handle(msg) else { continue }
            if let rdata = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) {
                writeLock.lock()
                out.write(rdata); out.write(newline)
                writeLock.unlock()
            }
        }
        exit(0)
    }
}
