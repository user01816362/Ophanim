//
//  OPConfig.swift
//  OphanimCore
//
//  Per-app instrumentation configuration + interception rules. Written by the GUI into the
//  app's settings plist and read by the in-process agent at constructor time. Mirror this
//  struct field-for-field on the GUI side; decoding tolerates missing keys via defaults.
//

import Foundation

/// Sink selection: where records are written. Combinable.
///
/// - Note: Guest-shared (compiles into host AND guest): keep the dialect
///   old-Swift-safe (see §4 of `docs/CODING-STANDARDS.md`).
public struct OPSinkSelection: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let ndjson    = OPSinkSelection(rawValue: 1 << 0)
    public static let plainText = OPSinkSelection(rawValue: 1 << 1)
    public static let osLog     = OPSinkSelection(rawValue: 1 << 2)
    public static let all: OPSinkSelection = [.ndjson, .plainText, .osLog]
}

/// Predicate matching a call against a rule. All present fields must match (AND).
///
/// Guest-shared (compiles into host AND guest): keep the dialect
/// old-Swift-safe. Each glob is a shell-style `*`/`?` full-string match.
public struct OPMatcher: Codable, Sendable {
    public var categories: [OPCategory]?       // any-of
    public var apiGlob: String?                // glob on the api name, e.g. "SecItem*"
    public var hostGlob: String?               // network: host glob, e.g. "*.analytics.com"
    public var urlGlob: String?                // network: full-URL glob
    public var pathGlob: String?               // filesystem: path glob, e.g. "*/Library/jb*"
    public var argContains: String?            // substring present in any stringified arg

    public init() {}
}

/// Action a matched rule performs.
///
/// `script`, when present, is evaluated via JavaScriptCore and takes
/// precedence over the static fields below it. Guest-shared (compiles into
/// host AND guest): keep the dialect old-Swift-safe.
public struct OPAction: Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case observe, modifyArgs, replaceReturn, block, delay, fault, script
    }
    public var kind: Kind
    public var script: String?                 // JS source for `.script`
    // static payloads:
    public var replacementBodyBase64: String?  // network/file: replacement bytes
    public var replacementHeaders: [String: String]?
    public var replacementStatus: Int?         // network: HTTP status
    public var cannedReturnValue: String?      // device/keychain: stringified return
    public var cannedArgs: [String: String]?   // inline: {"x0":"0x…"} register rewrites (modifyArgs)
    public var delayMilliseconds: Int?
    public var faultErrorCode: Int?

    public init(kind: Kind) { self.kind = kind }
}

/// A single interception rule.
///
/// First matching enabled rule wins (`OPInterceptor.decide`). Longer-lived
/// than any one call: the engine holds the list for the config generation.
///
/// - Parameter id: Stable identifier, also used for per-rule JS `ctx.state`.
/// - Parameter enabled: Disabled rules are filtered at `OPInterceptor` init.
/// - Parameter note: Human-readable purpose.
/// - Parameter match: Predicate — all present fields must match (AND).
/// - Parameter action: What to do on match.
public struct OPRule: Codable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var note: String?
    public var match: OPMatcher
    public var action: OPAction

    public init(id: String, enabled: Bool = true, note: String? = nil,
                match: OPMatcher, action: OPAction) {
        self.id = id; self.enabled = enabled; self.note = note
        self.match = match; self.action = action
    }
}

/// A user-specified ObjC boundary hook: swizzles (className, selector) and logs the call + its object args.
///
/// Lets analysts capture any @objc boundary (e.g. an SDK's response handler)
/// without code changes. Pure-Swift (non-@objc) methods are not reachable
/// this way — those need inline hooking.
///
/// - Parameter className: ObjC class name.
/// - Parameter selector: Selector string.
/// - Parameter args: Number of object args (0–3) to forward + log.
/// - Parameter classMethod: True = swizzle the class (+) method, false = instance (-).
/// - Parameter category: Which capture category to log under.
/// - Parameter api: Display label (defaults to `className.selector`).
/// - Parameter imageGlob: Only hook when the class's dyld image matches (e.g. `*UIKit*`); nil/empty = match everything.
public struct OPObjCHook: Codable, Sendable {
    public var className: String
    public var selector: String
    public var args: Int            // number of object args (0–3) to forward + log
    public var classMethod: Bool    // true = swizzle the class (+) method, false = instance (-)
    public var category: OPCategory // which capture category to log under
    public var api: String?         // display label (defaults to "className.selector")
    public var imageGlob: String?   // P6: only hook when the class's dyld image matches (e.g. "*UIKit*")

    public init(className: String, selector: String, args: Int = 1, classMethod: Bool = false,
                category: OPCategory = .process, api: String? = nil, imageGlob: String? = nil) {
        self.className = className; self.selector = selector; self.args = args
        self.classMethod = classMethod; self.category = category; self.api = api
        self.imageGlob = imageGlob
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        className = try c.decode(String.self, forKey: .className)
        selector = try c.decode(String.self, forKey: .selector)
        args = try c.decodeIfPresent(Int.self, forKey: .args) ?? 1
        classMethod = try c.decodeIfPresent(Bool.self, forKey: .classMethod) ?? false
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        api = try c.decodeIfPresent(String.self, forKey: .api)
        imageGlob = try c.decodeIfPresent(String.self, forKey: .imageGlob)
    }
}

/// A native-Swift vtable hook (Tier 2.5): patches an overridable Swift method's vtable slot to log the call (and pass through).
///
/// Reaches non-@objc Swift that ObjC swizzling cannot — but only methods
/// dispatched through the vtable (polymorphic/cross-module; `-O` may
/// devirtualize concrete calls).
///
/// - Parameter className: ObjC-runtime class name (the _TtC… form `find_symbols` reports).
/// - Parameter method: Substring matched against the slot's (mangled) symbol.
/// - Parameter category: Which capture category to log under.
/// - Parameter api: Display label.
/// - Parameter imageGlob: Only hook when the class's dyld image matches (e.g. `*MyApp*`); nil/empty = match everything.
public struct OPSwiftHook: Codable, Sendable {
    public var className: String    // ObjC-runtime class name (the _TtC… form find_symbols reports)
    public var method: String       // substring matched against the slot's (mangled) symbol
    public var category: OPCategory
    public var api: String?
    public var imageGlob: String?   // P6: only hook when the class's dyld image matches (e.g. "*MyApp*")

    public init(className: String, method: String, category: OPCategory = .process, api: String? = nil,
                imageGlob: String? = nil) {
        self.className = className; self.method = method; self.category = category; self.api = api
        self.imageGlob = imageGlob
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        className = try c.decode(String.self, forKey: .className)
        method = try c.decode(String.self, forKey: .method)
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        api = try c.decodeIfPresent(String.self, forKey: .api)
        imageGlob = try c.decodeIfPresent(String.self, forKey: .imageGlob)
    }
}

/// Image scoping for language-boundary hooks (P6).
///
/// `dladdr()`s the class pointer and glob-matches its dyld image path, so one
/// config can span app + extensions without cross-talk (e.g. imageGlob
/// `*UIKit*` skips an app class of the same name). nil/empty glob = match
/// everything (existing behavior, zero cost when unused).
public enum OPImageScope {
    /// Whether a class's dyld image matches a glob.
    ///
    /// - Parameter glob: Shell-style `*`/`?` pattern, case-insensitive; nil/empty matches everything.
    /// - Parameter cls: Class whose image path is resolved via `dladdr()`.
    /// - Returns: True on match; false when `dladdr()` fails or the pattern does not match.
    public static func matches(_ glob: String?, class cls: AnyClass) -> Bool {
        guard let g = glob, !g.isEmpty else { return true }
        var info = Dl_info()
        guard dladdr(unsafeBitCast(cls, to: UnsafeRawPointer.self), &info) != 0,
              let fname = info.dli_fname else { return false }
        return globMatch(g, String(cString: fname))
    }

    /// Minimal shell-glob (`*`/`?`, case-insensitive, full-string). Kept local instead of
    /// reusing OPGlob: OPInterceptor.swift is guest-only, while this file also compiles
    /// into the host app target (OPConfig + OPEvent only).
    private static func globMatch(_ pattern: String, _ text: String) -> Bool {
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx += ".*"
            case "?": rx += "."
            default: rx += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        rx += "$"
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// How an inline hook renders a selected argument/return register.
///
/// Deref it as an ObjC object (NSData → captured as a body; NSString → a
/// field; any object → its description) or as a C string. Validated before
/// any deref so a non-object register value falls back to raw hex (never
/// crashes).
public enum OPArgRender: String, Codable, Sendable, CaseIterable {
    case nsdata      // [NSData] → ctx.requestBody/responseBody (+ "argN":"<N bytes>")
    case nsstring    // [NSString] → fields["argN"] = value
    case objcDesc    // any object → fields["argN"] = description (capped)
    case cString     // char* → fields["argN"] = UTF8 string (bounded)
}

/// A Tier-3 inline (machine-code) hook: patches a function's prologue so calls divert through the engine (intercept / modify args+return / log).
///
/// The target is located, in priority order, by: `address` (absolute hex),
/// `symbol` (`dlsym`; `followThunk` chases a leading B), `module`+`offset`
/// (Ghidra static offset + ASLR slide), or `module`+`signature` (wildcard
/// byte pattern `AA BB ?? D1`). arm64 only; gated behind
/// `OPConfig.enableInlineHooks` (live code patching).
///
/// - Parameter api: Display label for captured events.
/// - Parameter category: Which capture category to log under.
/// - Parameter module: Substring of the image's dyld path (default: main executable).
/// - Parameter symbol: Symbol name resolved via `dlsym`.
/// - Parameter address: Absolute runtime address, hex (`0x…`).
/// - Parameter offset: Static offset within `module` (hex or decimal).
/// - Parameter signature: Byte pattern, e.g. `1F 20 03 D5 ?? ?? ?? 94`.
/// - Parameter followThunk: Follow a leading unconditional B to the real body.
/// - Parameter captureReturn: Also run the original and log/modify its return value (implied when `renderReturn` is set).
/// - Parameter renderArgs: Deref renderers per arg register, e.g. `{"x2":"nsstring"}`.
/// - Parameter renderReturn: Renderer for the return value.
public struct OPInlineHook: Codable, Sendable {
    public var api: String              // display label for captured events
    public var category: OPCategory
    public var module: String?          // substring of the image's dyld path (default: main executable)
    public var symbol: String?
    public var address: String?         // absolute runtime address, hex ("0x…")
    public var offset: String?          // static offset within `module` (hex or decimal)
    public var signature: String?       // byte pattern, e.g. "1F 20 03 D5 ?? ?? ?? 94"
    public var followThunk: Bool        // follow a leading unconditional B to the real body
    public var captureReturn: Bool      // also run the original and log/modify its return value
    public var renderArgs: [String: OPArgRender]?   // {"x2":"nsstring","x3":"nsdata"} - deref arg regs
    public var renderReturn: OPArgRender?            // render the return value (captureReturn/leave path)

    public init(api: String, category: OPCategory = .process, module: String? = nil,
                symbol: String? = nil, address: String? = nil, offset: String? = nil,
                signature: String? = nil, followThunk: Bool = false, captureReturn: Bool = false,
                renderArgs: [String: OPArgRender]? = nil, renderReturn: OPArgRender? = nil) {
        self.api = api; self.category = category; self.module = module; self.symbol = symbol
        self.address = address; self.offset = offset; self.signature = signature
        self.followThunk = followThunk; self.captureReturn = captureReturn
        self.renderArgs = renderArgs; self.renderReturn = renderReturn
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        api = try c.decode(String.self, forKey: .api)
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        module = try c.decodeIfPresent(String.self, forKey: .module)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        offset = try c.decodeIfPresent(String.self, forKey: .offset)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        followThunk = try c.decodeIfPresent(Bool.self, forKey: .followThunk) ?? false
        captureReturn = try c.decodeIfPresent(Bool.self, forKey: .captureReturn) ?? false
        renderArgs = try c.decodeIfPresent([String: OPArgRender].self, forKey: .renderArgs)
        renderReturn = try c.decodeIfPresent(OPArgRender.self, forKey: .renderReturn)
        // captureReturn is implied when a return renderer is requested
        if renderReturn != nil { captureReturn = true }
    }
}

/// How the engine gets into the hosted process.
///
/// Embedded ships inside Galgal (always present, dormant until enabled).
/// Sibling injects a standalone agent dylib via a 2nd LC_LOAD_DYLIB. This is
/// an install-time concern; the default is embedded.
public enum OPInjectionStrategy: String, Codable, Sendable, CaseIterable {
    case embedded
    case sibling
}

/// Top-level per-app config. Observe-by-default: with no rules, every hook only logs.
///
/// Guest-shared (compiles into host AND guest): keep the dialect
/// old-Swift-safe. Decoding is lenient — adding fields later never
/// invalidates an existing settings plist.
public struct OPConfig: Codable, Sendable {
    public var enabled: Bool
    public var injectionStrategy: OPInjectionStrategy   // install-time concern; default embedded
    public var categories: [OPCategory]                 // which capture modules are active
    public var sinks: OPSinkSelection
    public var logToSharedDir: Bool                     // ~/Library/Logs/Ophanim vs app container
    public var bodyCapBytes: Int                        // max captured payload size
    public var captureBacktraces: Bool
    public var captureNetworkCallers: Bool   // dladdr symbolication per request (default off, hot-path cost)
    public var redactionKeys: [String]                  // header/field keys whose values are masked ([] = nothing redacted)
    public var rules: [OPRule]
    public var autoOpenLog: Bool                         // GUI: open the log window when the app launches
    public var bypassPinning: Bool                       // force-accept SecTrust (defeat cert pinning)
    public var objcHooks: [OPObjCHook]                   // user-specified ObjC boundary hooks
    public var swiftHooks: [OPSwiftHook]                 // user-specified native-Swift vtable hooks
    public var inlineHooks: [OPInlineHook]               // Tier-3 inline (machine-code) hooks
    public var enableInlineHooks: Bool                   // explicit gate for live code patching
    public var agentMode: Bool                           // Inspect agent-mode providers. Default OFF.
    public var inspectDisableRedaction: Bool             // Inspect: hand capture raw. Default OFF.

    public init(enabled: Bool = false,
                injectionStrategy: OPInjectionStrategy = .embedded,
                categories: [OPCategory] = OPCategory.allCases,
                sinks: OPSinkSelection = [.ndjson],
                logToSharedDir: Bool = false,
                bodyCapBytes: Int = 64 * 1024,
                captureBacktraces: Bool = false,
                captureNetworkCallers: Bool = false,
                redactionKeys: [String] = [],   // nothing redacted by default - this is an analysis tool
                rules: [OPRule] = [],
                autoOpenLog: Bool = false,
                bypassPinning: Bool = false,
                objcHooks: [OPObjCHook] = [],
                swiftHooks: [OPSwiftHook] = [],
                inlineHooks: [OPInlineHook] = [],
                enableInlineHooks: Bool = false,
                agentMode: Bool = false,
                inspectDisableRedaction: Bool = false) {
        self.enabled = enabled
        self.injectionStrategy = injectionStrategy
        self.categories = categories
        self.sinks = sinks
        self.logToSharedDir = logToSharedDir
        self.bodyCapBytes = bodyCapBytes
        self.captureBacktraces = captureBacktraces
        self.captureNetworkCallers = captureNetworkCallers
        self.redactionKeys = redactionKeys
        self.rules = rules
        self.autoOpenLog = autoOpenLog
        self.bypassPinning = bypassPinning
        self.objcHooks = objcHooks
        self.swiftHooks = swiftHooks
        self.inlineHooks = inlineHooks
        self.enableInlineHooks = enableInlineHooks
        self.agentMode = agentMode
        self.inspectDisableRedaction = inspectDisableRedaction
    }

    // Lenient decoding so adding fields later never invalidates an existing settings plist.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OPConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        injectionStrategy = try c.decodeIfPresent(OPInjectionStrategy.self, forKey: .injectionStrategy) ?? d.injectionStrategy
        categories = try c.decodeIfPresent([OPCategory].self, forKey: .categories) ?? d.categories
        sinks = try c.decodeIfPresent(OPSinkSelection.self, forKey: .sinks) ?? d.sinks
        logToSharedDir = try c.decodeIfPresent(Bool.self, forKey: .logToSharedDir) ?? d.logToSharedDir
        bodyCapBytes = try c.decodeIfPresent(Int.self, forKey: .bodyCapBytes) ?? d.bodyCapBytes
        captureBacktraces = try c.decodeIfPresent(Bool.self, forKey: .captureBacktraces) ?? d.captureBacktraces
        captureNetworkCallers = try c.decodeIfPresent(Bool.self, forKey: .captureNetworkCallers) ?? d.captureNetworkCallers
        redactionKeys = try c.decodeIfPresent([String].self, forKey: .redactionKeys) ?? d.redactionKeys
        rules = try c.decodeIfPresent([OPRule].self, forKey: .rules) ?? d.rules
        autoOpenLog = try c.decodeIfPresent(Bool.self, forKey: .autoOpenLog) ?? d.autoOpenLog
        bypassPinning = try c.decodeIfPresent(Bool.self, forKey: .bypassPinning) ?? d.bypassPinning
        objcHooks = try c.decodeIfPresent([OPObjCHook].self, forKey: .objcHooks) ?? d.objcHooks
        swiftHooks = try c.decodeIfPresent([OPSwiftHook].self, forKey: .swiftHooks) ?? d.swiftHooks
        inlineHooks = try c.decodeIfPresent([OPInlineHook].self, forKey: .inlineHooks) ?? d.inlineHooks
        enableInlineHooks = try c.decodeIfPresent(Bool.self, forKey: .enableInlineHooks) ?? d.enableInlineHooks
        agentMode = try c.decodeIfPresent(Bool.self, forKey: .agentMode) ?? d.agentMode
        inspectDisableRedaction = try c.decodeIfPresent(Bool.self, forKey: .inspectDisableRedaction) ?? d.inspectDisableRedaction
    }

    /// Whether a capture category is currently active.
    ///
    /// - Parameter category: Category to test.
    /// - Returns: True only when instrumentation is enabled AND the category is selected.
    public func isActive(_ category: OPCategory) -> Bool {
        enabled && categories.contains(category)
    }
}

/// Resolves and loads the per-app OPConfig.
///
/// The agent re-derives the plist path purely from the process identity, so it
/// works in both the embedded-runtime and sibling-dylib injection modes.
public enum OPConfigLoader {
    /// Container "App Settings" plist the GUI writes, keyed by the *host* app's bundle id.
    ///
    /// - Parameter hostBundleID: Defaults to the current process's bundle ID.
    /// - Returns: URL of the settings plist for that app.
    public static func defaultURL(hostBundleID: String = Bundle.main.bundleIdentifier ?? "") -> URL {
        // homeDirectoryForCurrentUser is unavailable on iOS/Catalyst; derive the real user home
        // the same way the runtime reads its settings plist.
        return OPPaths.userHome
            .appendingPathComponent("Library/Containers/be.ophanim.Ophanim/App Settings")
            .appendingPathComponent(hostBundleID)
            .appendingPathExtension("plist")
    }

    /// Loads the config, defaulting to disabled when nothing is stored.
    ///
    /// Lenient: a missing file or an envelope without an `ophanim` key yields
    /// a default `OPConfig`, never a throw.
    ///
    /// - Parameter url: Settings plist URL. Defaults to `defaultURL()`.
    /// - Returns: The stored config, or a default when absent/undecodable.
    public static func load(from url: URL = OPConfigLoader.defaultURL()) -> OPConfig {
        guard let data = try? Data(contentsOf: url) else { return OPConfig() }
        // The settings plist embeds the Ophanim config under a known key; decode leniently.
        if let cfg = try? PropertyListDecoder().decode(OPConfigEnvelope.self, from: data) {
            return cfg.ophanim ?? OPConfig()
        }
        return OPConfig()
    }
}

/// The GUI's settings-model envelope.
///
/// Only the `ophanim` field is decoded; everything else in the plist is
/// ignored, which is what keeps old/new readers compatible.
public struct OPConfigEnvelope: Codable, Sendable {
    public var ophanim: OPConfig?
}

/// Path helpers that work identically on macOS (GUI) and iOS/Mac Catalyst (in-process agent).
public enum OPPaths {
    /// The real user home.
    ///
    /// `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS, and a
    /// sandboxed Catalyst app's `NSHomeDirectory()` points at its container —
    /// so derive it from the login name, matching how the runtime locates its
    /// settings plist.
    ///
    /// - Returns: `/Users/<login>` as a file URL.
    public static var userHome: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())")
    }

    /// Ophanim's own app-container root.
    ///
    /// The hosted app's sandbox profile grants read-write here (the agent
    /// already loads its settings plist from this tree), and unlike
    /// `~/Library/Logs/Ophanim` it needs no extra sbpl exception.
    ///
    /// - Returns: `~/Library/Containers/be.ophanim.Ophanim` as a file URL.
    public static var ophanimContainer: URL {
        userHome.appendingPathComponent("Library/Containers/be.ophanim.Ophanim")
    }

    /// Canonical capture-log directory for a hosted app, keyed by its bundle id.
    ///
    /// Under Ophanim's container. Both the in-app agent (writer) and the
    /// GUI/MCP (readers) resolve logs through here so the location does NOT
    /// depend on how macOS names the app's *data* container — that name is a
    /// random UUID for any app lacking an `application-identifier` entitlement
    /// (e.g. an ad-hoc re-signed app), which is what made capture readback
    /// silently return nothing.
    ///
    /// - Parameter bundleID: Host app bundle ID (`unknown` when empty).
    /// - Returns: The log directory URL.
    public static func logDirectory(forBundleID bundleID: String) -> URL {
        ophanimContainer
            .appendingPathComponent("Logs")
            .appendingPathComponent(bundleID.isEmpty ? "unknown" : bundleID)
    }

    /// Pre-fix log location: the hosted app's own data container.
    ///
    /// Only correct for apps whose data container is bundle-id-named, but
    /// still read so logs captured before the fix stay visible.
    ///
    /// - Parameter bundleID: Host app bundle ID.
    /// - Returns: The legacy log directory URL.
    public static func legacyLogDirectory(forBundleID bundleID: String) -> URL {
        userHome.appendingPathComponent("Library/Containers/\(bundleID)/Data/Documents/Ophanim")
    }
}
