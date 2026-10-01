import Foundation

/// The single liveness + Agent-Mode gate every inspect-family entry passes through.
enum InspectGate {
    /// Returns the per-app config plus the effective redaction flag.
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
