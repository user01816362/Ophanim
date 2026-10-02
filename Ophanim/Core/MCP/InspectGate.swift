import Foundation

/// The single liveness + Agent-Mode gate every inspect-family entry passes through.
///
/// Liveness is the shared definition (`InspectControl.isAppRunning`), never a bare
/// workspace check: a client-spawned `--mcp` child can see an empty
/// `runningApplications` list while the app runs fine.
enum InspectGate {
    /// Requires the app installed, alive, and Agent-Mode armed. Returns the
    /// per-app instrumentation config plus the effective redaction flag.
    ///
    /// - Parameter bundleID: The app's bundle identifier (from `list_apps`).
    /// - Returns: The app's `OPConfig` and whether tree/snapshot text stays redacted.
    /// - Throws: `ToolRouter.bail` when the app is not installed, not running,
    ///   or Agent Mode is off (each naming its fix: install, `launch_app`, or
    ///   enable Agent Mode and relaunch).
    static func requireLive(bundleID bid: String) throws -> (ophanim: OPConfig, redacted: Bool) {
        guard AppQueryService.appURL(bid) != nil else {
            throw ToolRouter.bail("app not installed: \(bid)")
        }
        guard InspectControl.isAppRunning(bundleID: bid) else {
            throw ToolRouter.bail("app not running: \(bid) - launch it first (launch_app), then retry")
        }
        guard let settings = SettingsStore.appSettings(bid)?.ophanim else {
            throw ToolRouter.bail("Agent Mode is not enabled for \(bid); turn it on in the app's Hacking settings, then relaunch the app")
        }
        guard settings.agentMode == true else {
            throw ToolRouter.bail("Agent Mode is not enabled for \(bid); turn it on in the app's Hacking settings, then relaunch the app")
        }
        return (settings, !(settings.inspectDisableRedaction))
    }
}
