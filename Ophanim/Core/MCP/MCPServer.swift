//
//  MCPServer.swift
//  Ophanim
//
//  Transport-agnostic JSON-RPC 2.0 + MCP lifecycle core. Dispatches `tools/call`
//  through ToolRouter.handlers (one proxy map); tool logic lives in Tools/*,
//  data access in Services/*, framing in Transports/*.
//

import Foundation

final class MCPServer {
    nonisolated(unsafe) static let shared = MCPServer()
    private let serverName = "ophanim"
    private let serverVersion = "1.0.0"

    /// Protocol revisions this server implements. `2026-07-28` is stateless
    /// (version travels per-request in `_meta`); older revisions negotiate
    /// through the `initialize` handshake.
    static let supportedProtocolVersions = ["2026-07-28", "2025-06-18", "2025-11-25"]

    /// The specification's error code for an unimplemented version. The server
    /// MUST list what it supports so a client can retry.
    static let versionErrorCode = -32022

    private static let metaProtocolVersion = "io.modelcontextprotocol/protocolVersion"

    /// The version a request declared, if any. Modern requests carry it in
    /// `_meta`; a request with no version is treated as legacy.
    ///
    /// - Parameter params: The JSON-RPC `params` object.
    /// - Returns: The declared protocol version, or nil when absent.
    private static func requestedVersion(_ params: [String: Any]) -> String? {
        guard let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta[metaProtocolVersion] as? String
    }

    /// Tools that change no state. Everything else defaults to mutating.
    static let readOnlyTools: Set<String> = [
        "list_apps", "tool_matrix", "launch_status", "query_events", "tail_events", "export_curl", "analyze_app", "app_imports",
        "find_symbols", "list_libraries", "scan_signature",
        "get_config", "get_hooks", "validate_rule_script",
        "list_jailbreak_detectors", "list_presets",
        "list_sources", "search_source_apps", "refresh_sources",
        "get_log_path", "sqlite_tables", "sqlite_rows", "keychain_items", "container_read",
        "container_info", "list_profiles",
        "list_tweaks", "inspect_tweak", "list_keymaps", "get_keymap",
        "list_classes", "uitree_read", "screenshot",
        "inspect_pick", "inspect_pasteboard", "inspect_focus", "find_element",
        "inspect_classes", "inspect_element", "inspect_class_detail",
        "inspect_snapshot", "inspect_timeline", "inspect_diff", "bookmark_list"
    ]

    /// Tools that delete or replace state (preview first where offered).
    static let destructiveTools: Set<String> = [
        "install_app", "uninstall_app", "terminate_app", "set_galgal_runtime",
        "set_dyld_libraries", "set_app_category", "prune_files",
        "set_config", "set_injection_strategy", "reset_settings",
        "set_keymap", "rename_keymap", "delete_keymap",
        "set_rules", "apply_preset", "remove_rule", "set_rule_enabled",
        "set_objc_hooks", "set_swift_hooks", "set_inline_hooks", "suggest_hooks", "remove_hook",
        "add_source", "remove_source", "rename_source", "edit_source_url",
        "reset_sources", "install_source_app", "source_transfer",
        "add_tweak", "move_tweak", "remove_tweak", "set_tweak_enabled",
        "tweak_folder", "resync_tweaks",
        "clear_logs", "create_profile", "remove_profile", "switch_profile",
        "clear_container", "backup_container", "restore_container",
        "set_pref",
        "inspect_clear_snapshots",
        "bookmark_add", "bookmark_note", "bookmark_move", "bookmark_remove",
        "tap_element", "swipe", "set_text", "tap_and_read",
    ]

    /// Dispatch one JSON-RPC message. Returns the response object, or nil for notifications.
    ///
    /// Version-gates modern (`_meta`-carrying) requests, then serves the MCP
    /// lifecycle (`initialize`, `tools/list`, `tools/call`) from the static
    /// catalog. Unknown methods answer `-32601`, never a guess.
    ///
    /// - Parameter msg: The decoded JSON-RPC message.
    /// - Returns: The response object, or nil for notifications (no reply).
    func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]

        // Version gate, modern era only. A request declaring an unimplemented
        // version is rejected with the supported list so the client can retry.
        if let requested = Self.requestedVersion(params),
           !Self.supportedProtocolVersions.contains(requested) {
            return error(id, code: Self.versionErrorCode, message: "Unsupported protocol version",
                         data: ["supported": Self.supportedProtocolVersions, "requested": requested])
        }

        switch method {
        case "server/discover":
            return Self.result(id, [
                "resultType": "complete",
                "supportedVersions": Self.supportedProtocolVersions,
                "capabilities": ["tools": [:] as [String: Any]],
                "ttlMs": 300000,
                "instructions": "Ophanim instruments iOS apps running on macOS. Use list_apps to "
                    + "find a bundle ID, query_events to read captured behavior, get_config/set_config "
                    + "to inspect and change what is captured, and launch_app to run one."
            ])
        case "initialize":
            let pv = params["protocolVersion"] as? String ?? "2025-06-18"
            return Self.result(id, [
                "protocolVersion": pv,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": "Ophanim instruments iOS apps running on macOS. Use list_apps to "
                    + "find a bundle ID, query_events to read captured behavior, get_config/set_config "
                    + "to inspect and change what is captured, and launch_app to run one."
            ])
        case "ping":
            return Self.result(id, [:])
        case "notifications/initialized", "notifications/cancelled":
            return nil   // notifications take no reply
        case "tools/list":
            return Self.result(id, ["tools": Self.toolDefinitions.map { toolDef -> [String: Any] in
                var annotated = toolDef
                if let name = annotated["name"] as? String {
                    annotated["annotations"] = ["readOnlyHint": Self.readOnlyTools.contains(name),
                                        "destructiveHint": Self.destructiveTools.contains(name)]
                }
                return annotated
            }, "ttlMs": 300000, "cacheScope": "process"])
        case "tools/call":
            return callTool(id, name: params["name"] as? String ?? "",
                            arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tool dispatch (via ToolRouter.handlers)

    /// Per-tool call budget within a rolling minute.
    private static let rateLimitPerMinute = 120
    nonisolated(unsafe) private static var callLog: [String: [Date]] = [:]
    private static let rateLogLock = NSLock()

    /// Seconds the caller must wait, or nil if the call is allowed.
    ///
    /// Rolling per-tool window (`rateLimitPerMinute` per `MCPTimeouts.rateWindow`):
    /// the oldest call in the window is what must age out first.
    ///
    /// - Parameter tool: The wire name being rate-checked.
    /// - Returns: The wait in seconds, or nil when the call may proceed.
    private func rateLimited(tool: String) -> Int? {
        Self.rateLogLock.lock()
        defer { Self.rateLogLock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-MCPTimeouts.rateWindow)
        var recent = (Self.callLog[tool] ?? []).filter { $0 > cutoff }
        Self.callLog[tool] = recent
        guard recent.count >= Self.rateLimitPerMinute else {
            recent.append(now)
            Self.callLog[tool] = recent
            return nil
        }
        // The oldest call in the window is the one that has to age out first.
        let wait = (recent.first ?? now).addingTimeInterval(MCPTimeouts.rateWindow).timeIntervalSince(now)
        return max(1, Int(ceil(wait)))
    }

    /// Runs one `tools/call`: rate-limits, then routes inspect tools to their
    /// full-response path and everything else through `runTool`.
    ///
    /// Tool failures arrive as `isError` results with self-correcting text,
    /// never as JSON-RPC errors — except the rate-limit refusal, which states
    /// the wait so the caller retries instead of guessing.
    ///
    /// - Parameter id: The request id echoed in the response.
    /// - Parameter name: The tool wire name.
    /// - Parameter args: The tool's `arguments` object.
    /// - Returns: The response object (always non-nil for `tools/call`).
    private func callTool(_ id: Any?, name: String, arguments args: [String: Any]) -> [String: Any]? {
        // Per-tool limit so a chatty read cannot starve a destructive call; the
        // refusal states the wait so a model retries rather than guesses.
        if let retry = rateLimited(tool: name) {
            return Self.toolError(id, "rate limited: \(name) has been called \(Self.rateLimitPerMinute) times in "
                + "the last minute. Wait \(retry) second\(retry == 1 ? "" : "s") and retry.")
        }
        // Inspect tools return full responses (including image blocks), not Strings.
        if InspectTools.inspectToolNames.contains(name) {
            do {
                return try InspectTools.runInspectTool(id, name, args)
            } catch let e as ToolRouter.ToolError {
                return Self.toolError(id, "Error: \(e.message)")
            } catch {
                return Self.toolError(id, "Error: \(error.localizedDescription)")
            }
        }
        do {
            let text = try runTool(name, args)
            // A JSON object result is both the legacy content block and the
            // serialised structuredContent; a plain message gets the text form.
            if let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
               let object = payload as? [String: Any] {
                return Self.toolResult(id, object)
            }
            return Self.toolText(id, text)
        } catch let e as ToolRouter.ToolError {
            return Self.toolError(id, "Error: \(e.message)")
        } catch {
            return Self.toolError(id, "Error: \(error.localizedDescription)")
        }
    }

    /// Looks up the handler in `ToolRouter.handlers` and runs it.
    ///
    /// - Parameter name: The tool wire name.
    /// - Parameter args: The tool's `arguments` object.
    /// - Returns: The handler's JSON text (object payload or plain message).
    /// - Throws: `ToolRouter.bail` (`unknown tool: <name>`) for unregistered names.
    private func runTool(_ name: String, _ args: [String: Any]) throws -> String {
        guard let handler = ToolRouter.handlers[name] else { throw ToolRouter.bail("unknown tool: \(name)") }
        return try handler(args)
    }

    // MARK: JSON-RPC helpers

    /// Wraps a result payload in the JSON-RPC envelope.
    ///
    /// - Parameter id: The request id (null when absent).
    /// - Parameter value: The `result` object.
    /// - Returns: The enveloped response.
    static func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    /// A tool result with machine-readable payload: `resultType` marks it
    /// complete, `structuredContent` carries the payload, and the text block
    /// keeps older clients working.
    ///
    /// - Parameter id: The request id echoed in the response.
    /// - Parameter payload: The JSON object mirrored as text and structured content.
    /// - Returns: The enveloped tool result.
    static func toolResult(_ id: Any?, _ payload: [String: Any]) -> [String: Any] {
        let text = (try? ToolRouter.json(payload)) ?? "{}"
        return Self.result(id, [
            "resultType": "complete",
            "content": [["type": "text", "text": text]],
            "structuredContent": payload
        ])
    }

    /// Plain-text tool success (for handlers returning a message, not JSON).
    ///
    /// - Parameter id: The request id echoed in the response.
    /// - Parameter message: The human-readable confirmation.
    /// - Returns: The enveloped tool result with `isError: false`.
    static func toolText(_ id: Any?, _ message: String) -> [String: Any] {
        Self.result(id, [
            "resultType": "complete",
            "content": [["type": "text", "text": message]],
            "isError": false
        ])
    }

    /// Tool failure with a self-correcting message (fix the name/args, then retry).
    ///
    /// - Parameter id: The request id echoed in the response.
    /// - Parameter message: The `Error: …` text shown to the caller.
    /// - Returns: The enveloped tool result with `isError: true`.
    static func toolError(_ id: Any?, _ message: String) -> [String: Any] {
        Self.result(id, [
            "resultType": "complete",
            "content": [["type": "text", "text": message]],
            "isError": true
        ])
    }
    /// Image result per the spec content-block shape ({type, data, mimeType}) plus
    /// dimensions as structured content. Text fallback first so pre-structuredContent
    /// clients still get a readable summary.
    ///
    /// - Parameter id: The request id echoed in the response.
    /// - Parameter base64: The base-64 image bytes.
    /// - Parameter mimeType: The image media type (e.g. `image/jpeg`).
    /// - Parameter summary: The text-block fallback (dimensions + redaction state).
    /// - Parameter structured: The machine-readable payload (bundleID, width, height).
    /// - Returns: The enveloped tool result with text + image blocks.
    static func toolResultImage(_ id: Any?, base64: String, mimeType: String,
                                summary: String, structured: [String: Any]) -> [String: Any] {
        Self.result(id, [
            "resultType": "complete",
            "content": [["type": "text", "text": summary],
                        ["type": "image", "data": base64, "mimeType": mimeType]],
            "structuredContent": structured
        ])
    }

    /// JSON-RPC error envelope (method/version failures, not tool failures —
    /// those answer `isError` via `toolError`).
    ///
    /// - Parameter id: The request id (null when absent).
    /// - Parameter code: The JSON-RPC error code.
    /// - Parameter message: The error text.
    /// - Parameter data: Optional machine-readable detail (e.g. supported versions).
    /// - Returns: The enveloped error response.
    private func error(_ id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var body: [String: Any] = ["code": code, "message": message]
        if let data { body["data"] = data }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": body]
    }

    // MARK: Tool catalog

    nonisolated(unsafe) static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_apps",
            "description": "List the iOS apps installed in Ophanim, with each app's bundle ID, name, "
                + "version, whether instrumentation is enabled, and which capture categories are active.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "tool_matrix",
            "description": "Machine-readable contract matrix: readOnly/destructive + dryRun behavior (default/explicit/none/na) per tool. Consult before mutating calls.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "query_events",
            "description": "Return captured instrumentation events for an app (filesystem, network, "
                + "keychain, crypto, process, jailbreak, etc.), newest last. Optionally filter by "
                + "category and/or a free-text search across api/summary/fields.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier (from list_apps)."],
                    "category": ["type": "string", "description": "Optional category filter, e.g. network, filesystem, keychain, crypto, process, jailbreak, device, privacy."],
                    "search": ["type": "string", "description": "Optional case-insensitive substring matched against api, summary, and field values."],
                    "limit": ["type": "integer", "description": "Max events to return (default 200, newest kept)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "tail_events",
            "description": "Stream new captured events since a cursor. Pass the `cursor` returned by a "
                + "previous call as `since` to get only events captured since then - for live monitoring.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "since": ["type": "number", "description": "Cursor (epoch milliseconds) from a prior call; omit/0 for the latest batch."],
                    "limit": ["type": "integer", "description": "Max events to return (default 100, newest)."],
                    "waitMs": ["type": "integer", "description": "Long-poll: block up to N ms (max 30000) for new events instead of returning empty. Default 0."],
                    "category": ["type": "string", "description": "Optional category filter (cursor still advances on all events)."],
                    "search": ["type": "string", "description": "Optional case-insensitive substring over api/summary/fields."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "subscribe_events",
            "description": "Push cursor+count notifications (notifications/events/added) on stdout; bodies via tail_events. Stdio children only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "since": ["type": "number", "description": "Cursor (epoch ms); omit/0 for latest."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "unsubscribe_events",
            "description": "Stop push notifications (one bundleID, or all when omitted).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "Omit to unsubscribe all."]
                ]
            ]
        ],
        [
            "name": "analyze_app",
            "description": "Produce a behavior/privacy report for an app from its captured events: hosts "
                + "contacted, identifiers & privacy APIs accessed, keychain items, crypto usage, jailbreak "
                + "probes/bypasses, certificate-pinning activity, and processes/libraries/URLs launched.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_presets",
            "description": "List ready-made rule presets (block-trackers, fake-idfv, fake-idfa, block-host {host}, fake-device-id {value}) you can apply with apply_preset. block-trackers breaks deep-link resolution + in-app ads while active.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "apply_preset",
            "description": "Apply a named rule preset to an app (merges into existing rules, by id). "
                + "block-trackers blocks known tracker/analytics/ad hosts; fake-idfv/fake-idfa return fixed fake identifiers; "
                + "block-host takes parameters.host; fake-device-id takes parameters.value.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "preset": ["type": "string", "description": "Preset name: block-trackers | fake-idfv | fake-idfa | block-host | fake-device-id."],
                    "parameters": ["type": "object", "description": "Template parameters for block-host ({host}) and fake-device-id ({value})."]
                ],
                "required": ["bundleID", "preset"]
            ]
        ],
        [
            "name": "set_rules",
            "description": "Replace an app's interception rules. Each rule = {id, enabled, note?, "
                + "match:{categories?,apiGlob?,hostGlob?,urlGlob?,pathGlob?,argContains?}, "
                + "action:{kind, ...}} where kind ∈ observe|block|delay|fault|modifyArgs|replaceReturn|script. "
                + "For script rules set action.script to JS that reads/sets ctx (ctx.block=true, "
                + "ctx.returnValue, ctx.replacementBody[base64], ctx.replacementStatus, ctx.x0-x7 inline arg edits, "
                + "ctx.state.* per-rule persistent strings; reads ctx.method/ctx.statusCode). modifyArgs also accepts "
                + "cannedArgs {x0:..} for inline register rewrites. Takes effect live on a running app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "rules": ["type": "array", "items": ["type": "object"], "description": "Full rules array (replaces existing). Validate script rules with validate_rule_script first."],
                    "dryRun": ["type": "boolean", "description": "Preview only: pass true to validate + report counts without writing (omitted writes)."]
                ],
                "required": ["bundleID", "rules"]
            ]
        ],
        [
            "name": "remove_rule",
            "description": "Remove one interception rule by id (surgical alternative to full-array set_rules).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "id": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to remove."]
                ],
                "required": ["bundleID", "id"]
            ]
        ],
        [
            "name": "set_rule_enabled",
            "description": "Enable/disable one interception rule by id (surgical alternative to full-array set_rules).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "id": ["type": "string"],
                    "enabled": ["type": "boolean"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to apply."]
                ],
                "required": ["bundleID", "id", "enabled"]
            ]
        ],
        [
            "name": "validate_rule_script",
            "description": "Syntax-check a JS rule body without writing anything (parses only, never executes). Use before set_rules.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "script": ["type": "string", "description": "JS source for action.script (ctx mutation contract)."]
                ],
                "required": ["script"]
            ]
        ],
        [
            "name": "get_hooks",
            "description": "Read an app's three hook arrays (ObjC, Swift vtable, inline) plus the inline gate. "
                + "Lightweight twin of get_config for hook polling (no hosting dump).",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "get_config",
            "description": "Read an app's full per-app config as JSON, grouped into `instrumentation` "
                + "(the engine: enabled, capture categories, sinks, rules, bypassPinning, injection "
                + "strategy) and `hosting` (everything else the app persists: jailbreak bypasses, "
                + "ChainGuard/keychain emulation, reported iOS device model, and window/graphics/input "
                + "options). Mirrors what set_config can write.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "app_imports",
            "description": "Report an app's dynamically-imported TLS/crypto/keychain/process symbols - "
                + "the surface DYLD_INTERPOSE can hook. Crucial for statically-linked apps: even a "
                + "self-contained binary imports the OS's crypto/TLS primitives (e.g. Secure Transport "
                + "SSLRead/SSLWrite, SecTrustEvaluate), and those calls are interposable.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "find_symbols",
            "description": "Search an app binary for symbols / ObjC class & selector names matching a "
                + "keyword - recon for finding @objc boundary hook targets (then hook with set_objc_hooks). "
                + "Returns demangled symbols, Swift class names, and selectors.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "keyword": ["type": "string", "description": "Substring to match (e.g. 'Cronet', 'Response', 'didReceive')."]
                ],
                "required": ["bundleID", "keyword"]
            ]
        ],
        [
            "name": "suggest_hooks",
            "description": "Draft ObjC boundary hooks from a keyword using the LIVE runtime inventory (frida-trace shape, host-only). Pairings come from inspect_class_detail (void methods, 0-3 args only); non-void/arity mismatches are counted skipped. dryRun previews (default true — unlike hook writers, which default-write); pass false to merge new hooks into the app's set.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "keyword": ["type": "string", "description": "Substring matched against live class + method names."],
                    "category": ["type": "string", "description": "Capture category for drafts (default process)."],
                    "maxClasses": ["type": "integer", "description": "Live classes inventoried (default 5, cap 10)."],
                    "maxHooks": ["type": "integer", "description": "Draft cap (default 10, cap 20)."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to install new drafts."]
                ],
                "required": ["bundleID", "keyword"]
            ]
        ],
        [
            "name": "set_objc_hooks",
            "description": "Install ObjC boundary hooks: swizzle (className, selector) and log each call "
                + "+ its object args (NSData captured as a body). The ObjC-swizzle capture point for SDKs / the "
                + "@objc layer of statically-linked apps. Only void methods are hooked (callback shape), "
                + "and only objc_msgSend-dispatched calls are intercepted (runtime/cross-module/dynamic "
                + "invocations) - direct Swift calls and pure-Swift (non-@objc) methods aren't reachable. "
                + "Each hook = {className, selector, "
                + "args(0-3), classMethod(bool), category, api?, imageGlob? (dyld image filter, e.g. '*UIKit*')}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing; dropped entries are reverted live on next config poll)."],
                    "dryRun": ["type": "boolean", "description": "Preview only: pass true to validate + report counts without writing (omitted writes)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "remove_hook",
            "description": "Remove one hook by array index (surgical alternative to full-array set_*_hooks; P5 reverts it live on next config poll).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "kind": ["type": "string", "description": "objc, swift, or inline."],
                    "index": ["type": "integer", "description": "Position in the array (see get_hooks)."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to remove."]
                ],
                "required": ["bundleID", "kind", "index"]
            ]
        ],
        [
            "name": "set_swift_hooks",
            "description": "Install native-Swift vtable hooks: patch an overridable Swift "
                + "method's vtable slot to log each call and pass through. Reaches non-@objc Swift that "
                + "set_objc_hooks can't - but ONLY methods dispatched through the vtable "
                + "(polymorphic/overridable/cross-module). The -O optimizer devirtualizes concrete-type "
                + "calls into direct calls that bypass the vtable and aren't intercepted; pure static/struct "
                + "dispatch needs inline hooking. arm64 only; observe-only (void methods). Use find_symbols "
                + "to locate the runtime class name (_TtC… form) and the mangled method symbol. "
                + "Each hook = {className, method (substring matched against the slot's mangled symbol), "
                + "category, api?, imageGlob? (dyld image filter)}. "
                + "Install failures aggregate in ophanim.swiftHook.installSummary events.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing; dropped entries are reverted live on next config poll)."],
                    "dryRun": ["type": "boolean", "description": "Preview only: pass true to validate + report counts without writing (omitted writes)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "set_inline_hooks",
            "description": "Install inline (machine-code) hooks - patch a function's prologue to "
                + "intercept/modify/log it, reaching statically-linked / stripped / static-dispatch code "
                + "that ObjC, Swift-vtable, and interpose hooks can't. arm64 only; gated behind "
                + "set_config enableInlineHooks=true (live code patching). Locate the target (priority "
                + "order) by: address (absolute hex), symbol (dlsym; set followThunk for exported Swift), "
                + "module+offset (Ghidra static offset + ASLR slide), or module+signature (wildcard byte "
                + "pattern \"1F 20 ?? D5\"). Args x0-x3 and the return are captured; an interception rule "
                + "(set_rules, matched on the api label) can block / replace the return. Each hook = "
                + "{api, category, module?, symbol?, address?, offset?, signature?, followThunk?, "
                + "captureReturn?, renderArgs?, renderReturn?}. renderArgs maps arg registers to an ObjC "
                + "renderer, e.g. {\"x2\":\"nsstring\",\"x3\":\"nsdata\"}, so a register holding an NSData is "
                + "captured as a body (and NSString as a field) instead of a raw pointer "
                + "(nsdata|nsstring|objcDesc|cString; safe-deref, falls back to hex). renderReturn does the "
                + "same for the return value (implies captureReturn). A modifyArgs rule additionally "
                + "rewrites x0-x7 on entry via action.cannedArgs (or first body bytes into x0).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing; dropped entries are reverted live on next config poll)."],
                    "dryRun": ["type": "boolean", "description": "Preview only: pass true to validate + report counts without writing (omitted writes)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "list_jailbreak_detectors",
            "description": "List the jailbreak/root-detection SDKs Ophanim can bypass (id + label). Use "
                + "these ids with set_config's jailbreakBypasses, or pass \"all\" to enable every one.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "set_config",
            "description": "Modify an app's per-app settings. Any omitted field is left unchanged. "
                + "Changes persist to the per-app settings; capture categories, rules, sinks and pinning "
                + "apply live to a running app (config is watched), while newly added hooks and the "
                + "injection strategy take effect on next launch.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "enabled": ["type": "boolean", "description": "Turn the instrumentation engine on/off."],
                    "autoOpenLog": ["type": "boolean", "description": "Open the log window when the app launches."],
                    "captureBacktraces": ["type": "boolean", "description": "Record calling stacks for ObjC-level events (device/privacy/attestation/process)."],
                    "bypassPinning": ["type": "boolean", "description": "Force certificate-pinning checks to succeed (defeat pinning). Logged under the network category."],
                    "enableInlineHooks": ["type": "boolean", "description": "Master gate for inline (machine-code) hooks. Off by default; must be on before any set_inline_hooks target is patched (live code patching)."],
                    "categories": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Replace the active capture categories. Valid values: network, keychain, crypto, device, privacy, filesystem, process, jailbreak."
                    ],
                    "sinks": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Replace the output sinks. Valid values: ndjson, text, console."
                    ],
                    "jailbreakBypass": ["type": "boolean", "description": "Master switch for jailbreak/root-detection bypassing."],
                    "jailbreakBypasses": [
                        "description": "Which detector SDKs to bypass. Pass \"all\" or \"none\", or an array of detector ids (see list_jailbreak_detectors).",
                        "oneOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]
                    ],
                    "chainGuard": ["type": "boolean", "description": "Route keychain calls through ChainGuard (emulated keychain)."],
                    "chainGuardDebugging": ["type": "boolean", "description": "Log each ChainGuard keychain read/write."],
                    "captureNetworkCallers": ["type": "boolean", "description": "Symbolicate network callers in-process (default off, hot-path cost)."],
                    "logToSharedDir": ["type": "boolean", "description": "Write capture logs to ~/Library/Logs/Ophanim instead of the app container."],
                    "bodyCapBytes": ["type": "integer", "description": "Max captured payload bytes per event (1024-8388608)."],
                    "redactionKeys": ["type": "array", "items": ["type": "string"], "description": "Header/field keys whose values are masked."],
                    "spoofedOSVersion": ["type": "string", "description": "iOS version the app reports (empty = off)."],
                    "agentMode": ["type": "boolean", "description": "Arm Inspect agent-mode providers in the guest."],
                    "inspectDisableRedaction": ["type": "boolean", "description": "Hand capture to AI raw (explicit consent)."],
                    "openWithLLDB": ["type": "boolean", "description": "Launch attached to LLDB (Debugger groupbox)."],
                    "openLLDBWithTerminal": ["type": "boolean", "description": "Run LLDB inside Terminal instead of attaching silently."],
                    "clearLogsOnLaunch": ["type": "boolean", "description": "Fresh log each launch instead of history."],
                    "customTweakFolder": ["type": "string", "description": "Custom tweak directory (empty resets to default; must exist)."],
                    "iosDeviceModel": ["type": "string", "description": "iOS hardware model the app reports (e.g. iPad13,8)."],
                    "disableDisplaySleep": ["type": "boolean", "description": "Hold a no-display-sleep assertion while the app runs (useful for long capture sessions)."],
                    "keymapping": ["type": "boolean", "description": "Enable keyboard-to-touch key mapping."],
                    "sensitivity": ["type": "number", "description": "Mouse/camera-control sensitivity (0-100)."],
                    "alwaysOnTop": ["type": "boolean", "description": "Keep the app's window above other windows."],
                    "hideTitleBar": ["type": "boolean", "description": "Hide the app window's title bar."],
                    "rootWorkDir": ["type": "boolean", "description": "Start the app with its working directory at /."],
                    "limitMotionUpdateFrequency": ["type": "boolean", "description": "Throttle accelerometer/gyro callbacks."],
                    "blockSleepSpamming": ["type": "boolean", "description": "Suppress rapid-fire sleep calls."],
                    "checkMicPermissionSync": ["type": "boolean", "description": "Resolve the microphone-permission check synchronously."],
                    "noKMOnInput": ["type": "boolean", "description": "Suspend key mapping while a text field is focused."],
                    "enableScrollWheel": ["type": "boolean", "description": "Forward scroll-wheel events to the app."],
                    "disableBuiltinMouse": ["type": "boolean", "description": "Ignore the built-in trackpad for mouse control."],
                    "metalHUD": ["type": "boolean", "description": "Show the Metal performance HUD."],
                    "notch": ["type": "boolean", "description": "Report a display notch (safe-area inset)."],
                    "inverseScreenValues": ["type": "boolean", "description": "Invert screen coordinate mapping."],
                    "displayRotation": ["type": "integer", "description": "Display rotation mode."],
                    "windowWidth": ["type": "integer", "description": "Hosted window width in points."],
                    "windowHeight": ["type": "integer", "description": "Hosted window height in points."],
                    "customScaler": ["type": "number", "description": "Custom resolution scale factor."],
                    "resolution": ["type": "integer", "description": "Resolution preset index (0 = off; 6 = resizable)."],
                    "aspectRatio": ["type": "integer", "description": "Aspect-ratio preset index."],
                    "windowFixMethod": ["type": "integer", "description": "Window-sizing fix strategy index."],
                    "resizableAspectRatioType": ["type": "integer", "description": "Resizable aspect-ratio lock type."],
                    "resizableAspectRatioWidth": ["type": "integer", "description": "Locked aspect-ratio width component."],
                    "resizableAspectRatioHeight": ["type": "integer", "description": "Locked aspect-ratio height component."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "launch_app",
            "description": "Launch an installed app so it runs with its current instrumentation config. Pass openURL to open a deep link after launch.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "openURL": ["type": "string", "description": "Deep link to open post-launch (URL schemes + universal links)."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "launch_status",
            "description": "Pump-aware liveness: workspace running flag + inspect gate + config switch. Answers whether the app is up AND instrumented.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "terminate_app",
            "description": "Terminate a running app (graceful quit, force-kill fallback). Needed because launch_app on a running app only activates — restart-required config changes need this first.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "force": ["type": "boolean", "description": "Skip graceful quit."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to terminate."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "install_app",
            "description": "Install (import) an iOS .ipa as a hosted app - the same flow as dropping an "
                + ".ipa into the Ophanim window: unpack it, convert the Mach-O to Mac Catalyst, re-sign "
                + "it, inject the Galgal runtime + instrumentation engine, and register it. Galgal is "
                + "always injected (no prompt). After it returns, configure with set_config and run with "
                + "launch_app. Returns the installed bundle id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ipaPath": ["type": "string", "description": "Filesystem path to the .ipa to install (a leading ~ is expanded)."]
                ],
                "required": ["ipaPath"]
            ]
        ],
        [
            "name": "uninstall_app",
            "description": "Uninstall a hosted app: remove its bundle and per-app config (settings, "
                + "keymap, entitlements, ChainGuard) - the set the GUI's uninstall clears. The app's data "
                + "container, including its captured event logs, is preserved unless purgeData is true.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "purgeData": ["type": "boolean", "description": "Also delete the app's data container (its captured event logs). Default false."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report what would be removed, incl. container resolution. Pass false to delete."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "set_galgal_runtime",
            "description": "Install or remove the Galgal runtime in an app's executable (settings-window Galgal button). Rewrites load commands.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "installed": ["type": "boolean", "description": "True = install Galgal, false = remove it."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to rewrite."]
                ],
                "required": ["bundleID", "installed"]
            ]
        ],
        [
            "name": "set_dyld_libraries",
            "description": "Toggle DYLD injected libraries (introspection, iosFrameworks). Re-signs the binary; next launch applies.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "introspection": ["type": "boolean", "description": "Inject /usr/lib/system/introspection."],
                    "iosFrameworks": ["type": "boolean", "description": "Inject iOSSupport frameworks path."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to re-sign."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "set_app_category",
            "description": "Set the app's LSApplicationCategoryType and re-sign (Application Type groupbox).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "category": ["type": "string", "description": "Raw category value, e.g. public.app-category.games."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to re-sign."]
                ],
                "required": ["bundleID", "category"]
            ]
        ],
        [
            "name": "prune_files",
            "description": "Trash per-app files left behind by uninstalled apps (prune-dangling-files setting).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): list what would be trashed. Pass false to trash."]
                ]
            ]
        ],
        [
            "name": "list_sources",
            "description": "List subscribed AltStore-format app-source feeds with app counts and errors.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "search_source_apps",
            "description": "Search all subscribed source feeds for apps by name, bundle ID, or developer (same filter as the Sources window search).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Substring to match (case-insensitive)."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "add_source",
            "description": "Subscribe an app-source feed by URL.",
            "inputSchema": [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "Feed URL (AltStore format)."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to subscribe."]],
                "required": ["url"]
            ]
        ],
        [
            "name": "remove_source",
            "description": "Unsubscribe an app-source feed by URL.",
            "inputSchema": [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "Feed URL."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to unsubscribe."]],
                "required": ["url"]
            ]
        ],
        [
            "name": "install_source_app",
            "description": "Download and install a feed app (optionally version-pinned), waiting to idle.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "version": ["type": "string", "description": "Optional pinned version."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report the version that would install. Pass false to install."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "refresh_sources",
            "description": "Re-fetch one feed (by URL) or all feeds. Cache sync, no data loss.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Feed URL to refresh; omit to refresh all."]
                ]
            ]
        ],
        [
            "name": "rename_source",
            "description": "Rename a subscribed feed's display name.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Feed URL."],
                    "name": ["type": "string", "description": "New display name."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to rename."]
                ],
                "required": ["url", "name"]
            ]
        ],
        [
            "name": "edit_source_url",
            "description": "Re-point a feed at a new URL (cache follows, old cache purged).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Current feed URL."],
                    "newUrl": ["type": "string", "description": "Replacement feed URL."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to re-point."]
                ],
                "required": ["url", "newUrl"]
            ]
        ],
        [
            "name": "reset_sources",
            "description": "Drop every custom source + caches + resume data (back to shipped empty state).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to drop all."]
                ]
            ]
        ],
        [
            "name": "source_transfer",
            "description": "Pause / resume / cancel an in-flight feed download (transfer ring menu).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "action": ["type": "string", "description": "pause, resume, or cancel."],
                    "version": ["type": "string", "description": "Resume with a pinned version (default: latest compatible)."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to act."]
                ],
                "required": ["bundleID", "action"]
            ]
        ],
        [
            "name": "list_tweaks",
            "description": "List an app's tweak store entries (dylib/framework/folder, enabled state).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "recursive": ["type": "boolean"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_tweak",
            "description": "Report loadability + Mach-O facts for a tweak file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "Accepted but unused (kept for call compatibility)."],
                    "path": ["type": "string"]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": "add_tweak",
            "description": "Copy a tweak into the store after a loadability check.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "path": ["type": "string"],
                    "replace": ["type": "boolean"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to copy."]
                ],
                "required": ["bundleID", "path"]
            ]
        ],
        [
            "name": "move_tweak",
            "description": "Rename a tweak inside the store.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "from": ["type": "string"],
                    "to": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to rename."]
                ],
                "required": ["bundleID", "from", "to"]
            ]
        ],
        [
            "name": "remove_tweak",
            "description": "Remove a tweak from the store.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to remove."]
                ],
                "required": ["bundleID", "name"]
            ]
        ],
        [
            "name": "set_tweak_enabled",
            "description": "Enable/disable a tweak (.disabled convention).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string"],
                    "enabled": ["type": "boolean"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to apply."]
                ],
                "required": ["bundleID", "name", "enabled"]
            ]
        ],
        [
            "name": "tweak_folder",
            "description": "Create/rename/remove a tweak subfolder.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "action": ["type": "string"],
                    "name": ["type": "string"],
                    "newName": ["type": "string", "description": "Required for action=rename."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to apply."]
                ],
                "required": ["bundleID", "action", "name"]
            ]
        ],
        [
            "name": "resync_tweaks",
            "description": "Re-sync the store into the app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "get_log_path",
            "description": "Capture log dirs + ndjson files with sizes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "sqlite_tables",
            "description": "List tables (+ row counts) of an app-container sqlite database. Read-only, path-confined to the app's container/logs.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "db": ["type": "string", "description": "Database path or filename substring."]
                ],
                "required": ["bundleID", "db"]
            ]
        ],
        [
            "name": "sqlite_rows",
            "description": "Read rows of one table (validated against the table list; capped 200 rows, long cells truncated). Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "db": ["type": "string", "description": "Database path or filename substring."],
                    "table": ["type": "string"],
                    "limit": ["type": "integer", "description": "Max rows (default 50, cap 200)."]
                ],
                "required": ["bundleID", "db", "table"]
            ]
        ],
        [
            "name": "keychain_items",
            "description": "Dump an app's ChainGuard (emulated keychain) items: service/account/secret triples. Sensitive by owner directive (own apps): values are NOT masked — never paste into shared contexts.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "limit": ["type": "integer", "description": "Max items (default 100, cap 500)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "container_read",
            "description": "Read one file inside the app's container/logs (plists decode to JSON; text capped; binary base64-capped). Read-only, path-confined.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "path": ["type": "string", "description": "Absolute path or container-relative path."],
                    "limit": ["type": "integer", "description": "Max bytes (default 8192, cap 65536)."]
                ],
                "required": ["bundleID", "path"]
            ]
        ],
        [
            "name": "set_pref",
            "description": "Set one scalar preference (string/number/boolean) in the app's preferences plist. Nested values refused.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "key": ["type": "string"],
                    "value": ["type": ["string", "number", "boolean"], "description": "Scalar value."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to write."]
                ],
                "required": ["bundleID", "key", "value"]
            ]
        ],
        [
            "name": "clear_logs",
            "description": "Delete capture logs, byte-counted.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to delete."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "container_info",
            "description": "Resolved container report.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_profiles",
            "description": "Container profiles + active + live check.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "create_profile",
            "description": "Snapshot live container into a profile.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to create."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "switch_profile",
            "description": "Swap live container to a profile.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): reports active/running/refusal. Pass false to switch."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "remove_profile",
            "description": "Delete a profile.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to delete."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "clear_container",
            "description": "Wipe caches, data container, keychain state, or the single preferences plist.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "scope": ["type": "string", "description": "caches, data, keychain, or preferences."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report targets + bytes. Pass false to wipe."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "backup_container",
            "description": "Zip the data container to a path.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "destPath": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to write the archive."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "restore_container",
            "description": "Restore a container backup.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "archivePath": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to restore."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_classes",
            "description": "Class/selector inventory (live runtime classes when Agent Mode runs, else static strings).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "filter": ["type": "string"],
                    "limit": ["type": "integer"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_libraries",
            "description": "Linked libraries of an app binary (otool -L; Recon libraries section).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "scan_signature",
            "description": "Byte-signature scan of an app binary (hex with ?? wildcards, e.g. '1F 20 ?? D5'; capped at 500 hits).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "pattern": ["type": "string", "description": "Byte pattern, e.g. '1F 20 ?? D5'."]
                ],
                "required": ["bundleID", "pattern"]
            ]
        ],
        [
            "name": "set_injection_strategy",
            "description": "Persist embedded/sibling strategy and settle load commands.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "strategy": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report current/requested. Pass false to rewrite load commands."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "get_keymap",
            "description": "Read-only keymap JSON.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "set_keymap",
            "description": "Write a whole keymap by name (validated: name gate, enforced bundle binding, backup, atomic replace; dryRun previews by default).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "name": ["type": "string", "description": "Keymap name (plain filename)."],
                    "keymap": ["type": "object", "description": "Full Keymap JSON (buttonModels, draggableButtonModels, joystickModel, mouseAreaModel, bundleIdentifier)."],
                    "allowBundleMismatch": ["type": "boolean", "description": "File a keymap bound to another bundle (default false, rejected)."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report decoded counts + overwrite/backup plan. Pass false to write."]
                ],
                "required": ["bundleID", "name", "keymap"]
            ]
        ],
        [
            "name": "reset_settings",
            "description": "Reset an app's settings to defaults (settings-window reset button; bundle binding preserved).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to reset."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_keymaps",
            "description": "List an app's keymap files with sizes and the default marker.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "rename_keymap",
            "description": "Rename a keymap file (order list follows).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "name": ["type": "string", "description": "Current keymap name."],
                    "newName": ["type": "string", "description": "New keymap name."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to rename."]
                ],
                "required": ["bundleID", "name", "newName"]
            ]
        ],
        [
            "name": "delete_keymap",
            "description": "Delete a keymap file (trash). Refuses the default keymap like the GUI does.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "name": ["type": "string", "description": "Keymap name to delete."],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true). Pass false to delete."]
                ],
                "required": ["bundleID", "name"]
            ]
        ],
        [
            "name": "uitree_read",
            "description": "Read the app UI tree (JSON text + structured summary). Nodes carry framework/layer; response names detected frameworks + scene.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "rootId": ["type": "string"],
                    "mode": ["type": "string"],
                    "filter": ["type": "string"],
                    "depthLimit": ["type": "integer"],
                    "nodeLimit": ["type": "integer"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "screenshot",
            "description": "Capture a screenshot (image block + dimensions). Response names detected frameworks + scene. Pass annotate:true to overlay actionable-node frames + class names (same membership as uitree nodes[]). Pass elementId to crop to that element's frame.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "annotate": ["type": "boolean"],
                    "elementId": ["type": "string", "description": "Crop to this element (same-mode id from uitree nodes[])."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "tap_element",
            "description": "Tap by element id or x/y with optional snapshot pins.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "elementId": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "mode": ["type": "string"],
                    "snapshot": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "find_element",
            "description": "Find nodes by text/label/class substring (case-insensitive) in a fresh tree. Returns matching ids for tap_element/set_text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "text": ["type": "string"],
                    "label": ["type": "string"],
                    "class": ["type": "string"],
                    "mode": ["type": "string"],
                    "limit": ["type": "integer", "description": "Max matches (default 20, cap 100)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "tap_and_read",
            "description": "Tap (by id or x/y) then return a fresh tree nodes[] showing what changed. Fused act+verify, no snapshot pins (v1).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "elementId": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "mode": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_pick",
            "description": "Resolve the frontmost view at normalized x/y to an elementId (hitTest-independent; disabled views resolve).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "mode": ["type": "string"]
                ],
                "required": ["bundleID", "x", "y"]
            ]
        ],
        [
            "name": "inspect_pasteboard",
            "description": "Read the general pasteboard string (nil when empty/non-text). Read-only copy-flow observer.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_focus",
            "description": "First-responder class (nil when unfocused) + application state. Read-only, no tree walk.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "export_curl",
            "description": "Render the newest matching recorded request as a replay-grade curl command.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "url": ["type": "string", "description": "Substring filter."],
                    "host": ["type": "string", "description": "Substring filter."],
                    "since": ["type": "number", "description": "Cursor (epoch ms)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "swipe",
            "description": "Swipe with optional snapshot pins.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "x1": ["type": "number"],
                    "y1": ["type": "number"],
                    "x2": ["type": "number"],
                    "y2": ["type": "number"],
                    "steps": ["type": "integer"],
                    "snapshot": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "set_text",
            "description": "Set text on an element with optional snapshot pins. Direct write for UITextField/views; tap-focus + insertText fallback for engine-rendered inputs (Flutter); web inputs refuse stated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "elementId": ["type": "string"],
                    "text": ["type": "string"],
                    "mode": ["type": "string"],
                    "snapshot": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_classes",
            "description": "Live runtime classes (falls back to binary with stated error).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "filter": ["type": "string"],
                    "limit": ["type": "integer"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_element",
            "description": "Single node detail + superclasses.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "elementId": ["type": "string"],
                    "mode": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_class_detail",
            "description": "Method/ivar inventory for a class.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "className": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_snapshot",
            "description": "Pin a tree (+optional screenshot) to the timeline.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "rootId": ["type": "string"],
                    "mode": ["type": "string"],
                    "filter": ["type": "string"],
                    "depthLimit": ["type": "integer"],
                    "nodeLimit": ["type": "integer"],
                    "withScreenshot": ["type": "boolean"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_timeline",
            "description": "Timeline with latest-pair diff.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "limit": ["type": "integer"],
                    "trigger": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_diff",
            "description": "Diff two snapshots.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "from": ["type": "string"],
                    "to": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "inspect_clear_snapshots",
            "description": "Delete the snapshot timeline (dryRun previews by default).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report what would be removed. Pass false to delete."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "bookmark_add",
            "description": "Pin a class, element, or symbol with comment/tags/group.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "kind": ["type": "string"],
                    "name": ["type": "string"],
                    "elementId": ["type": "string"],
                    "mode": ["type": "string"],
                    "snapshot": ["type": "string"],
                    "comment": ["type": "string"],
                    "tags": ["type": "string"],
                    "group": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "bookmark_note",
            "description": "Comment on a bookmark or group.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "id": ["type": "string"],
                    "ref": ["type": "string"],
                    "comment": ["type": "string"],
                    "tags": ["type": "string"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "bookmark_move",
            "description": "File bookmarks into groups (dryRun previews by default).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "group": ["type": "string"],
                    "add": ["type": "string"],
                    "remove": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report the resulting membership. Pass false to apply."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "bookmark_list",
            "description": "List bookmarks with staleness.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "limit": ["type": "integer"],
                    "kind": ["type": "string"],
                    "tag": ["type": "string"],
                    "group": ["type": "string"],
                    "checkFresh": ["type": "boolean"]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "bookmark_remove",
            "description": "Delete bookmarks/groups (dryRun previews by default).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string"],
                    "ids": ["type": "string"],
                    "dryRun": ["type": "boolean", "description": "Preview only (default true): report what would be removed. Pass false to delete."]
                ],
                "required": ["bundleID"]
            ]
        ],

    ]
}