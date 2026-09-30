//
//  HostedApp.swift
//  Ophanim
//

import Cocoa
import Foundation
import IOKit.pwr_mgt

class HostedApp: BaseApp, @unchecked Sendable {
    // MARK: - Static
    public static let bundleIDCacheURL = Galgal.ophanimContainer.appendingPathComponent("CACHE")

    public static var bundleIDCache: [String] {
        get throws {
            (try String(contentsOf: bundleIDCacheURL))
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
        }
    }

    // MARK: - Instance State
    var displaySleepAssertionID: IOPMAssertionID?
    public var isStarting = false
    var sessionDisableKeychain: Bool = false

    // MARK: - Init
    override init(appUrl: URL) {
        super.init(appUrl: appUrl)

        keymapping.reloadKeymapCache()

        // Hosted apps launch from within Ophanim (directly from the container bundle); we no
        // longer create ~/Applications aliases. Clean up any alias left by an earlier version.
        removeAlias()
    }

    // MARK: - Computed
    var searchText: String {
        info.displayName.lowercased()
            .appending(" ")
            .appending(info.bundleName)
            .lowercased()
    }

    var name: String {
        info.displayName.isEmpty ? info.bundleName : info.displayName
    }

    // MARK: - Paths / Singletons
    static let aliasDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications")
        .appendingPathComponent("Ophanim")

    lazy var aliasURL = HostedApp.aliasDirectory.appendingPathComponent(name).appendingPathExtension("app")
    lazy var chainGuardURL = KeyCover.chainGuardPath.appendingPathComponent(info.bundleIdentifier)

    lazy var settings = AppSettings(info)
    lazy var keymapping = Keymapping(info)
    lazy var container = AppContainer(bundleId: info.bundleIdentifier)

    // MARK: - Launch
    func launch() async {
        do {
            isStarting = true

            if prohibitedToPlay {
                await clearAllCache()
                throw OphanimError.appProhibited
            } else if maliciousProhibited {
                await clearAllCache()
                deleteApp()
                throw OphanimError.appMaliciousProhibited
            }

            AppsVM.shared.fetchApps()

            settings.sync()

            if try !Entitlements.areEntitlementsValid(app: self) {
                sign()
            }

            if try !isInfoPlistSigned() {
                try Shell.signApp(executable)
            }

            // Wait for keychain unlock to finish before continuing
            await unlockKeyCover()

            // If the app does not have Galgal, do not install PlugIns
            if hasGalgal() {
                try Galgal.installPluginInIPA(url)
            }

            if try !Galgal.isInstalled() {
                Log.shared.error("Galgal are not installed! Please move Ophanim.app into Applications!")
            } else if try !Macho.isMachoValidArch(executable) {
                Log.shared.error("The app threw an error during conversion.")
            } else {
                // Clear any debug-related env vars that could affect the launched app
                self.clearDebugAffectingEnvironment()

                if settings.openWithLLDB {
                    try Shell.lldb(executable, withTerminalWindow: settings.openLLDBWithTerminal)
                } else {
                    runAppExec() // Splitting to reduce complexity
                }

                // Auto-open this app's instrumentation log window when launched, if enabled.
                if settings.settings.ophanim.enabled, settings.settings.ophanim.autoOpenLog {
                    let bid = settings.info.bundleIdentifier
                    Task { @MainActor in LogWindowManager.shared.show(bundleID: bid) }
                }
            }
            isStarting = false
        } catch {
            Log.shared.error(error)
        }
    }
}

// MARK: - Policies
extension HostedApp {
    var prohibitedToPlay: Bool {
        HostedApp.PROHIBITED_APPS.contains(info.bundleIdentifier)
    }

    var maliciousProhibited: Bool {
        HostedApp.MALICIOUS_APPS.contains(info.bundleIdentifier)
    }

    static let PROHIBITED_APPS = [
        "com.activision.callofduty.shooter",
        "com.ea.ios.apexlegendsmobilefps",
        "com.tencent.tmgp.cod",
        "com.tencent.ig",
        "com.pubg.newstate",
        "com.pubg.imobile",
        "com.tencent.tmgp.pubgmhd",
        "com.dts.freefireth",
        "com.dts.freefiremax",
        "vn.vng.codmvn",
        "com.ngame.allstar.eu",
        "com.axlebolt.standoff2",
        "com.tencent.lolm"
    ]

    static let MALICIOUS_APPS = [
        "com.zhiliaoapp.musically"
    ]
}
