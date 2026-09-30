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
    static let shared = MCPServer()
    private let serverName = "ophanim"
    private let serverVersion = "1.0.0"

    /// Dispatch one JSON-RPC message. Returns the response object, or nil for notifications.
    func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let pv = params["protocolVersion"] as? String ?? "2025-06-18"
            return result(id, [
                "protocolVersion": pv,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": "Ophanim instruments iOS apps running on macOS. Use list_apps to "
                    + "find a bundle ID, query_events to read captured behavior, get_config/set_config "
                    + "to inspect and change what is captured, and launch_app to run one."
            ])
        case "ping":
            return result(id, [:])
        case "notifications/initialized", "notifications/cancelled":
            return nil   // notifications take no reply
        case "tools/list":
            return result(id, ["tools": Self.toolDefinitions])
        case "tools/call":
            return callTool(id, name: params["name"] as? String ?? "",
                            arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tool dispatch (via ToolRouter.handlers)

    private func callTool(_ id: Any?, name: String, arguments args: [String: Any]) -> [String: Any]? {
        do {
            let text = try runTool(name, args)
            return result(id, ["content": [["type": "text", "text": text]], "isError": false])
        } catch let e as ToolRouter.ToolError {
            return result(id, ["content": [["type": "text", "text": "Error: \(e.message)"]], "isError": true])
        } catch {
            return result(id, ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
        }
    }

    private func runTool(_ name: String, _ args: [String: Any]) throws -> String {
        guard let handler = ToolRouter.handlers[name] else { throw ToolRouter.bail("unknown tool: \(name)") }
        return try handler(args)
    }

    // MARK: JSON-RPC helpers

    private func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }
    private func error(_ id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: Tool catalog

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_apps",
            "description": "List the iOS apps installed in Ophanim, with each app's bundle ID, name, "
                + "version, whether instrumentation is enabled, and which capture categories are active.",
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
                    "limit": ["type": "integer", "description": "Max events to return (default 100, newest)."]
                ],
                "required": ["bundleID"]
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
            "description": "List ready-made rule presets (block-trackers, fake-idfv, fake-idfa) you can apply with apply_preset. block-trackers breaks deep-link resolution + in-app ads while active.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "apply_preset",
            "description": "Apply a named rule preset to an app (merges into existing rules, by id). "
                + "block-trackers blocks known tracker/analytics/ad hosts; fake-idfv/fake-idfa return fixed fake identifiers.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "preset": ["type": "string", "description": "Preset name: block-trackers | fake-idfv | fake-idfa."]
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
                + "ctx.returnValue, ctx.replacementBody[base64], ctx.replacementStatus). Takes effect live on a running app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "rules": ["type": "array", "items": ["type": "object"], "description": "Full rules array (replaces existing)."]
                ],
                "required": ["bundleID", "rules"]
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
            "name": "set_objc_hooks",
            "description": "Install ObjC boundary hooks: swizzle (className, selector) and log each call "
                + "+ its object args (NSData captured as a body). The ObjC-swizzle capture point for SDKs / the "
                + "@objc layer of statically-linked apps. Only void methods are hooked (callback shape), "
                + "and only objc_msgSend-dispatched calls are intercepted (runtime/cross-module/dynamic "
                + "invocations) - direct Swift calls and pure-Swift (non-@objc) methods aren't reachable. "
                + "Each hook = {className, selector, "
                + "args(0-3), classMethod(bool), category, api?}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
                ],
                "required": ["bundleID", "hooks"]
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
                + "category, api?}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
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
                + "same for the return value (implies captureReturn).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
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
            "description": "Launch an installed app so it runs with its current instrumentation config.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
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
                    "purgeData": ["type": "boolean", "description": "Also delete the app's data container (its captured event logs). Default false."]
                ],
                "required": ["bundleID"]
            ]
        ]
    ]
}