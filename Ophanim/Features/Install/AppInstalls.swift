//
//  AppInstalls.swift
//  Ophanim
//
//  The single post-install completion kernel for IPA installs: refresh the app
//  list + notify, on the main actor. URLHandler, AppLibraryView, and SourceInstalls
//  hand-rolled the same completion; they share this (each keeps its own
//  preamble/postamble via result/didFinish). The pipeline call itself
//  (Installer.install) is untouched — frozen, proven working.
//  Headless callers (MCP install_app) keep their own semaphore bridging and do
//  not route here.
//

import Foundation

enum AppInstalls {
    /// Install an IPA file through the standard pipeline. `injectGalgal` nil follows
    /// the import prefs (including its modal prompt); pass an explicit value for
    /// background callers (source installs, MCP) that cannot present a modal.
    /// `result` carries the installer's verdict (app URL, or nil on failure).
    /// Closures are @Sendable (Swift 6): keep caller captures to weak self + values.
    static func installIPA(at url: URL, injectGalgal: Bool? = nil,
                           result: (@Sendable (URL?) -> Void)? = nil,
                           didFinish: (@Sendable () async -> Void)? = nil) {
        Installer.install(ipaUrl: url, export: false, injectGalgal: injectGalgal,
                          returnCompletion: { installed in
            result?(installed)
            Task { @MainActor in
                await didFinish?()
                AppsVM.shared.fetchApps()
                NotifyService.shared.notify(
                    NSLocalizedString("notification.appInstalled", comment: ""),
                    NSLocalizedString("notification.appInstalled.message", comment: ""))
            }
        })
    }
}
