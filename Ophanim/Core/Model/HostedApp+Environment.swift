//
//  HostedApp+Environment.swift
//  Ophanim
//
//  HostedApp launch environment: DYLD paths, Metal/capture keys.
//

import Foundation
// MARK: - Environment Management
extension HostedApp {
    static let introspection: String = "/usr/lib/system/introspection"
    static let iosFrameworks: String = "/System/iOSSupport/System/Library/Frameworks"

    /// Common Metal and capture related environment keys used in multiple places
    private static let metalEnvKeys: [String] = [
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_LAYER",
        "MTL_DEBUG_LAYER",
        "METAL_API_VALIDATION",
        "METAL_SHADER_VALIDATION",
        "METAL_SHADER_VALIDATION_OPTIONS",
        "METAL_CAPTURE_ENABLED",
        "METAL_CAPTURE_OUTPUT_FILE",
        "METAL_CAPTURE_TYPE",
        "METAL_FORCE_LAZY_COMPILATION",
        "METAL_FRAME_CAPTURE_ENABLED",
        "METAL_ERROR_MODE",
        "MTLCaptureEnabled"
    ]

    // clear environment variables that can force debug wrappers or validation layers
    func clearDebugAffectingEnvironment() {
        // Clear DYLD_* variables inherited from Xcode or other debuggers
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }

        // Clear common Metal debug and capture related variables
        for key in HostedApp.metalEnvKeys {
            unsetenv(key)
        }
    }

    func runAppExec() {
        let config = NSWorkspace.OpenConfiguration()

        // Prevent propagating debugging-related variables to child process
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }
        for key in HostedApp.metalEnvKeys {
            unsetenv(key)
        }

        NSWorkspace.shared.openApplication(
            at: url,
            configuration: config,
            completionHandler: { runningApp, error in
                guard error == nil else { return }
                // Run a thread loop in the background to handle background tasks
                Task(priority: .background) {
                    if let runningApp = runningApp {
                        while !(runningApp.isTerminated) {
                            if runningApp.isActive {
                                self.disableTimeOut()
                            } else {
                                self.enableTimeOut()
                            }
                            sleep(1)
                        }
                        sleep(1)
                    }
                    // Things that are run after the app is closed
                    self.lockKeyCover()
                }
            }
        )
    }
}
