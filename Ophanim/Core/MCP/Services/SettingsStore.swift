import Foundation

/// Sole plist read/write owner for per-app settings. Read-only queries go to
/// AppQueryService; log aggregation goes to ReportBuilder.
enum SettingsStore {
    /// Decode the per-app AppSettingsData from its plist (the encoded settings model).
    static func appSettings(_ bundleID: String) -> AppSettingsData? {
        guard let data = try? Data(contentsOf: AppQueryService.settingsURL(bundleID)) else { return nil }
        return try? PropertyListDecoder().decode(AppSettingsData.self, from: data)
    }

    static func config(_ bundleID: String) -> OPConfig? { appSettings(bundleID)?.ophanim }

    /// Full view of an app's config, grouped so it is not a verbatim dump of the flat settings
    /// struct: `instrumentation` is the OphanimCore engine config; `hosting` is everything else
    /// (jailbreak bypass, keychain emulation, reported device model, and the window/graphics/input
    /// options). Nothing is hidden - an MCP client can read every field the app persists.
    static func configProjection(_ bundleID: String) -> [String: Any]? {
        guard let s = appSettings(bundleID) else { return nil }
        func asDict<T: Encodable>(_ value: T) -> [String: Any] {
            (try? JSONEncoder().encode(value))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        var hosting = asDict(s)
        hosting["ophanim"] = nil            // surfaced separately as `instrumentation`
        hosting["bundleIdentifier"] = nil   // surfaced as top-level `bundleID`
        return [
            "bundleID": bundleID.isEmpty ? s.bundleIdentifier : bundleID,
            "instrumentation": asDict(s.ophanim),
            "hosting": hosting
        ]
    }

    /// Mutate the full per-app settings and persist them. A running app picks the change up live via
    /// the agent's config-file poll (categories/rules/sinks/pinning); newly added hooks and the
    /// injection strategy apply on next launch.
    static func updateSettings(_ bundleID: String, _ mutate: (inout AppSettingsData) -> Void) throws {
        var settings = appSettings(bundleID) ?? AppSettingsData()
        if settings.bundleIdentifier.isEmpty { settings.bundleIdentifier = bundleID }
        mutate(&settings)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        try FileManager.default.createDirectory(at: AppQueryService.settingsDir, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: AppQueryService.settingsURL(bundleID))
    }

    /// Apply a set_config argument patch to settings. Unit-testable without JSON:
    /// pass a plain dictionary, assert on the mutated struct.
    static func applyPatch(_ args: [String: Any], to s: inout AppSettingsData) {
        // Instrumentation (OphanimCore)
        if let on = args["enabled"] as? Bool { s.ophanim.enabled = on }
        if let on = args["autoOpenLog"] as? Bool { s.ophanim.autoOpenLog = on }
        if let on = args["captureBacktraces"] as? Bool { s.ophanim.captureBacktraces = on }
        if let on = args["bypassPinning"] as? Bool { s.ophanim.bypassPinning = on }
        if let on = args["enableInlineHooks"] as? Bool { s.ophanim.enableInlineHooks = on }
        if let cats = args["categories"] as? [String] {
            s.ophanim.categories = OPCategory.allCases.filter { cats.contains($0.rawValue) }
        }
        if let sinks = args["sinks"] as? [String] {
            var sel: OPSinkSelection = []
            if sinks.contains("ndjson") { sel.insert(.ndjson) }
            if sinks.contains("text") || sinks.contains("plainText") { sel.insert(.plainText) }
            if sinks.contains("console") || sinks.contains("osLog") { sel.insert(.osLog) }
            s.ophanim.sinks = sel
        }
        // Jailbreak / root-detection bypass
        if let on = args["jailbreakBypass"] as? Bool { s.bypass = on }
        if let jb = args["jailbreakBypasses"] {
            if let str = jb as? String {
                s.jailbreakBypasses = (str == "all") ? JBBypassCatalog.allIDs : (str == "none" ? [] : s.jailbreakBypasses)
            } else if let arr = jb as? [String] {
                if arr == ["all"] { s.jailbreakBypasses = JBBypassCatalog.allIDs }
                else if arr == ["none"] || arr.isEmpty { s.jailbreakBypasses = [] }
                else { s.jailbreakBypasses = JBBypassCatalog.allIDs.filter { arr.contains($0) } }   // validated
            }
        }
        // Keychain emulation
        if let on = args["chainGuard"] as? Bool { s.chainGuard = on }
        if let on = args["chainGuardDebugging"] as? Bool { s.chainGuardDebugging = on }
        // Device model the app reports (relevant to how it fingerprints its environment)
        if let model = args["iosDeviceModel"] as? String { s.iosDeviceModel = model }
        // Hosting: window / display / graphics / input - full parity with the app's settings.
        if let on = args["disableDisplaySleep"] as? Bool { s.disableTimeout = on }
        if let on = args["keymapping"] as? Bool { s.keymapping = on }
        if let v = args["sensitivity"] as? Double { s.sensitivity = Float(v) }
        if let on = args["alwaysOnTop"] as? Bool { s.floatingWindow = on }
        if let on = args["hideTitleBar"] as? Bool { s.hideTitleBar = on }
        if let on = args["rootWorkDir"] as? Bool { s.rootWorkDir = on }
        if let on = args["limitMotionUpdateFrequency"] as? Bool { s.limitMotionUpdateFrequency = on }
        if let on = args["blockSleepSpamming"] as? Bool { s.blockSleepSpamming = on }
        if let on = args["checkMicPermissionSync"] as? Bool { s.checkMicPermissionSync = on }
        if let on = args["noKMOnInput"] as? Bool { s.noKMOnInput = on }
        if let on = args["enableScrollWheel"] as? Bool { s.enableScrollWheel = on }
        if let on = args["disableBuiltinMouse"] as? Bool { s.disableBuiltinMouse = on }
        if let on = args["metalHUD"] as? Bool { s.metalHUD = on }
        if let on = args["notch"] as? Bool { s.notch = on }
        if let on = args["inverseScreenValues"] as? Bool { s.inverseScreenValues = on }
        if let v = args["displayRotation"] as? Int { s.displayRotation = v }
        if let v = args["windowWidth"] as? Int { s.windowWidth = v }
        if let v = args["windowHeight"] as? Int { s.windowHeight = v }
        if let v = args["customScaler"] as? Double { s.customScaler = v }
        if let v = args["resolution"] as? Int { s.resolution = v }
        if let v = args["aspectRatio"] as? Int { s.aspectRatio = v }
        if let v = args["windowFixMethod"] as? Int { s.windowFixMethod = v }
        if let v = args["resizableAspectRatioType"] as? Int { s.resizableAspectRatioType = v }
        if let v = args["resizableAspectRatioWidth"] as? Int { s.resizableAspectRatioWidth = v }
        if let v = args["resizableAspectRatioHeight"] as? Int { s.resizableAspectRatioHeight = v }
    }
}
