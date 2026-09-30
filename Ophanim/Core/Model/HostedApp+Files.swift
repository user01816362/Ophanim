//
//  HostedApp+Files.swift
//  Ophanim
//

import Foundation
// MARK: - FS / Codesign
extension HostedApp {
    func hasAlias() -> Bool {
        FileManager.default.fileExists(atPath: aliasURL.path)
    }

    func isInfoPlistSigned() throws -> Bool {
        try Shell.run("/usr/bin/codesign", "-dv", executable.path).contains("Info.plist entries")
    }

    func showInFinder() {
        URL(fileURLWithPath: url.path).showInFinderAndSelectLastComponent()
    }

    func openAppCache() {
        container.containerUrl.showInFinderAndSelectLastComponent()
    }

    func clearAllCache() async {
        Uninstaller.clearExternalCache(info.bundleIdentifier)
    }

    func clearChainGuard() {
        FileManager.default.delete(at: chainGuardURL)
        FileManager.default.delete(at: chainGuardURL.appendingPathExtension("keyCover"))
        FileManager.default.delete(at: chainGuardURL.appendingPathExtension("db"))
    }

    func deleteApp() {
        FileManager.default.delete(at: URL(fileURLWithPath: url.path))
        AppsVM.shared.fetchApps()
    }

    func sign() {
        do {
            let tmpDir = FileManager.default.temporaryDirectory
            let tmpEnts = tmpDir
                .appendingEscapedPathComponent(ProcessInfo().globallyUniqueString)
                .appendingPathExtension("plist")
            let conf = try Entitlements.composeEntitlements(self)
            try conf.store(tmpEnts)
            try Shell.signAppWith(executable, entitlements: tmpEnts)
            try FileManager.default.removeItem(at: tmpEnts)
        } catch {
            print(error)
            Log.shared.error(error)
        }
    }
}
