//
//  HostedApp+KeyCover.swift
//  Ophanim
//

import Foundation
import AppKit
// MARK: - KeyCover
extension HostedApp {
    func unlockKeyCover() async {
        if KeyCover.shared.isKeyCoverEnabled() {
            let keychain = KeyCover.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, keychain.chainEncryptionStatus {
                try? await KeyCover.shared.unlockChain(keychain)

                if KeyCover.shared.keyCoverPlainTextKey == nil {
                    // Pop an alert telling the user that keychain was not unlocked
                    // and keychain is disabled for the session
                    Task { @MainActor in
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("keycover.alert.title", comment: "")
                        alert.informativeText = NSLocalizedString("keycover.alert.content", comment: "")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
                        alert.runModal()
                    }
                    settings.settings.chainGuard = false
                    sessionDisableKeychain = true
                }
            }
        }
    }

    func lockKeyCover() {
        if KeyCover.shared.isKeyCoverEnabled() {
            if sessionDisableKeychain {
                settings.settings.chainGuard = true
                sessionDisableKeychain = false
                return
            }

            let keychain = KeyCover.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, !keychain.chainEncryptionStatus {
                try? KeyCover.shared.lockChain(keychain)
            }
        }
    }
}
