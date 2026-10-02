//
//  Installer.swift
//  Ophanim
//
//  IPA install pipeline: unzip, entitlements save, Mach-O convert + sign, Galgal
//  inject, wrapper bundle, re-sign. Runs on a user-initiated Task; the Galgal prompt
//  hops to main synchronously (a modal cannot take an async hop).
//

import Foundation

/// IPA install pipeline (frozen, proven working): unzip → convert/sign → inject →
/// wrap → re-sign. Headless callers force the Galgal decision via `injectGalgal`
/// (no modal); GUI callers get the prompt unless Option is held.
class Installer {

    /// Asks whether to inject Galgal, honoring the "don't ask again" suppression.
    ///
    /// - Returns: True when Galgal should be injected.
    @MainActor
    static func installGalgalPopup() -> Bool {
        let (response, suppressed) = Log.modal(
            question: NSLocalizedString("alert.install.injectGalgalQuestion", comment: ""),
            text: NSLocalizedString("alert.install.galgalInformative", comment: ""),
            style: .informational,
            buttons: [NSLocalizedString("button.Yes", comment: ""),
                      NSLocalizedString("button.No", comment: "")],
            makeFirstDefault: true,
            suppressionTooltip: NSLocalizedString("alert.supression", comment: "String"))

        if suppressed {
            InstallPreferences.shared.showInstallPopup = false
            InstallPreferences.shared.alwaysInstallGalgal = response == .alertFirstButtonReturn
        }

        return response == .alertFirstButtonReturn
    }

    /// Maps install failures to user-facing strings (disk-full / quota-page /
    /// corrupted-IPA all surface as generic errors from the pipeline).
    ///
    /// - Parameter error: The pipeline error.
    /// - Returns: The localized message to log.
    static private func returnErrorString(error: Error) -> String {
        switch error.localizedDescription {
        case let str where str.contains("(disk full?)"): NSLocalizedString("alert.notSpace", comment: "")
        case let str where str.contains(".html"): NSLocalizedString("alert.quota.limit", comment: "")
        case let str where str.contains(".ipa"): NSLocalizedString("alert.corrupted", comment: "")
        default: NSLocalizedString(error.localizedDescription, comment: "")
        }
    }

    /// Sendable box for the completion handler so the install Task can call it
    /// without dragging a non-Sendable closure across isolation (same contract as before).
    private final class CompletionBox: @unchecked Sendable {
        let fn: (URL?) -> Void
        init(_ fn: @escaping (URL?) -> Void) { self.fn = fn }
    }

    // swiftlint:disable:next function_body_length
    /// Runs the full install pipeline on a user-initiated Task; completion fires with
    /// the installed app URL (nil on failure, after the error is already logged).
    ///
    /// - Parameter ipaUrl: The IPA file to install.
    /// - Parameter export: When true, re-injects and repacks an IPA instead of wrapping.
    /// - Parameter injectGalgal: Forced Galgal decision for headless callers (nil = prompt per prefs).
    /// - Parameter returnCompletion: Verdict callback (installed URL, or nil on failure).
    static func install(ipaUrl: URL, export: Bool, injectGalgal: Bool? = nil,
                        returnCompletion: @escaping (URL?) -> Void) {
        // If (the option key is held or the install galgal popup settings is true) and its not an export,
        //    then show the installer dialog. A non-nil injectGalgal (e.g. from the MCP server, which has
        //    no UI) forces the decision and skips the modal prompt.
        let installGalgal: Bool

        if let injectGalgal {
            installGalgal = injectGalgal
        } else if (ModifierKeyObserver.shared.isOptionKeyPressed
                || InstallPreferences.shared.showInstallPopup) && !export {
            // Modal answer needed synchronously; GUI import runs on main, MCP forces
            // injectGalgal above and never reaches here (it has no UI to present).
            // Dispatch-then-assert: sync gets us to main, assumeIsolated satisfies
            // the @MainActor contract without an async hop a modal cannot take.
            installGalgal = MainDispatch.sync { MainActor.assumeIsolated { installGalgalPopup() } }
        } else {
            installGalgal = InstallPreferences.shared.alwaysInstallGalgal
        }

        InstallVM.shared.next(.begin, 0.0, 0.0)

        let completionBox = CompletionBox(returnCompletion)
        Task(priority: .userInitiated) {
            let ipa = IPA(url: ipaUrl)

            do {
                InstallVM.shared.next(.unzip, 0.0, 0.5)
                try ipa.allocateTempDir()

                let app = try ipa.unzip()
                InstallVM.shared.next(.library, 0.5, 0.55)
                try saveEntitlements(app)
                let machos = resolveValidMachOs(app)
                app.validMachOs = machos

                InstallVM.shared.next(.galgal, 0.55, 0.85)

                for macho in machos {
                    if try Macho.isMachoEncrypted(atURL: macho) {
                        throw OphanimError.appEncrypted
                    }

                    if !export {
                        try Macho.convertMacho(macho)
                        try Shell.signMacho(macho)
                    }
                }

                if export {
                    try Galgal.injectInIPA(app.executable, payload: app.url)
                } else if installGalgal {
                    try await Galgal.installInIPA(app.executable)
                }

                if !export {
                    // -rwxr-xr-x
                    try app.executable.setBinaryPosixPermissions(0o755)
                    try removeMobileProvision(app)
                }

                let info = app.info
                info.assert(minimumVersion: 11.0)
                try info.write()
                InstallVM.shared.next(.wrapper, 0.85, 0.95)

                var finalURL: URL

                if export {
                    finalURL = try ipa.packIPABack(app: app.url)
                } else {
                    finalURL = try wrap(app)
                    let installedApp = HostedApp(appUrl: finalURL)

                    try installedApp.sign()
                }

                ipa.releaseTempDir()
                try ipa.removeQuarantine(finalURL)
                InstallVM.shared.next(.finish, 0.95, 1.0)
                completionBox.fn(finalURL)
            } catch {
                Log.shared.error(returnErrorString(error: error))
                ipa.releaseTempDir()

                InstallVM.shared.next(.failed, 0.95, 1.0)
                completionBox.fn(nil)
            }
        }
    }

    /// Finds the .app inside an unzipped Payload dir (first .app directory wins).
    ///
    /// - Parameter folderURL: The Payload directory.
    /// - Returns: The app handle.
    /// - Throws: `OphanimError.infoPlistNotFound` when no .app directory exists.
    static func fromIPA(detectingAppNameInFolder folderURL: URL) throws -> BaseApp {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)

        var url: URL?

        for entry in contents {
            guard entry.hasSuffix(".app") else {
                continue
            }

            let entryURL = folderURL.appendingEscapedPathComponent(entry)
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            url = entryURL
            break
        }

        guard let url = url else {
            throw OphanimError.infoPlistNotFound
        }

        return BaseApp(appUrl: url)
    }

    /// Returns an array of URLs to MachO files within the app
    static func resolveValidMachOs(_ baseApp: BaseApp) -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }

        var resolved: [URL] = []
        let serialQueue = DispatchQueue(label: "baseAppUrlResolver")

        baseApp.url.enumerateContents { url, attributes in
            // Mach-O magic scan: only regular files with a dylib-or-bare extension can be
            // images; the 4-byte magic check below is the real gate.
            guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize > 4 else {
                return
            }

            if !url.pathExtension.isEmpty && url.pathExtension != "dylib" {
                return
            }

            let handle = try FileHandle(forReadingFrom: url)

            defer {
                do {
                    try handle.close()
                } catch {
                    print("Failed to close FileHandle for \(url.absoluteString): \(error.localizedDescription)")
                }
            }

            guard let data = try handle.read(upToCount: 4) else {
                return
            }

            serialQueue.sync {
                switch Array(data) {
                case [202, 254, 186, 190]: resolved.append(url)
                case [207, 250, 237, 254]: resolved.append(url)
                default: return
                }
            }
        }

        return resolved
    }

    /// Dumps the executable's entitlements and stores them for the later re-sign step.
    static func saveEntitlements(_ baseApp: BaseApp) throws {
        let toSave = try Entitlements.dumpEntitlements(exec: baseApp.executable)
        try toSave.store(baseApp.entitlements)
    }

    /// Removes the iOS provisioning profile (invalid on macOS; re-sign replaces it).
    ///
    /// - Parameter baseApp: The unzipped app.
    /// - Throws: File removal failures.
    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }

    /// Generates a wrapper bundle for an iOS app that allows it to be launched from Finder and other macOS UIs
    static func wrap(_ baseApp: BaseApp) throws -> URL {
        let info = AppInfo(contentsOf: baseApp.url
            .appendingPathComponent("Info")
            .appendingPathExtension("plist"))
        let location = AppsVM.appDirectory
            .appendingEscapedPathComponent(info.bundleIdentifier)
            .appendingPathExtension("app")
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }

        try FileManager.default.moveItem(at: baseApp.url, to: location)
        return location
    }
}
