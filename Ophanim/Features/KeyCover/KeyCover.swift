//
//  KeyCover.swift
//  Ophanim
//
//  At-rest keychain (ChainGuard) encryption state. HARD-DISABLED in Ophanim (see
//  below): keychain data stays visible for instrumentation, never encrypted.
//

import Foundation
import CryptoKit
import SwiftUI
import Security

/// At-rest ChainGuard keychain encryption. Hard-disabled: isKeyCoverEnabled is
/// pinned false so nothing reads/writes the macOS login keychain or encrypts.
struct KeyCover {
    nonisolated(unsafe) static var shared = KeyCover()
    /// ChainGuard store dir, created on first access.
    static var chainGuardPath: URL {
        let chainGuardDir = Galgal.ophanimContainer.appendingPathComponent("ChainGuard")

        if !FileManager.default.fileExists(atPath: chainGuardDir.path) {
            do {
                try FileManager.default.createDirectory(at: chainGuardDir, withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        return chainGuardDir
    }

    // KeyCover is hard-disabled in Ophanim: an instrumentation tool wants the emulated keychain
    // visible, not encrypted, and KeyCover otherwise reads/writes a master key in the macOS login
    // keychain (a launch prompt). Hard-off here so it never touches the keychain regardless of any
    // previously-persisted preference. Remove these overrides to restore the upstream behavior.
    var keyCoverPlainTextKey: String?

    /// Hard-off: always false (see the file header). Keeps the emulated keychain
    /// visible for instrumentation and avoids the login-keychain prompt.
    ///
    /// - Returns: False, always.
    func isKeyCoverEnabled() -> Bool {
        return false
    }

    /// All ChainGuard keychains on disk (one per hosted app that touched keychain).
    ///
    /// - Returns: Key handles for every chain file found.
    func listKeychains() -> [KeyCoverKey] {
        // Enumerate all the keychains
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: KeyCover.chainGuardPath,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
        var keychainList: [KeyCoverKey] = []
        for keychain in keychains ?? [] {
            let keychainName = keychain.deletingPathExtension().lastPathComponent
            let keychain = KeyCoverKey(appBundleID: keychainName)
            keychainList.append(keychain)
        }
        return keychainList
    }

    /// Number of currently unencrypted chains (for the status line).
    ///
    /// - Returns: The unlocked count.
    func unlockedCount() -> Int {
        var count = 0
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    /// Decrypts one chain, prompting for the master password when none is in memory.
    /// Blocks on the prompt: the prompt is the sole producer of the in-memory key.
    ///
    /// - Parameter keychain: The chain to unlock.
    /// - Throws: Decryption failures from the key DB.
    func unlockChain(_ keychain: KeyCoverKey) async throws {
        if keyCoverPlainTextKey == nil {
            let task = Task {@MainActor in
                KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown = true
            }
            await task.value
            while KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown {
                sleep(1)
            }
        }
        if keychain.chainEncryptionStatus {
            try keychain.decryptKeyDB()
        }
    }

    /// Encrypts one unlocked chain (no-op without an in-memory key).
    ///
    /// - Parameter keychain: The chain to lock.
    /// - Throws: Encryption failures from the key DB.
    func lockChain(_ keychain: KeyCoverKey) throws {
        if keyCoverPlainTextKey == nil {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB()
        }
    }

    /// Encrypts every unlocked chain in the background (best-effort per chain).
    func lockAllChainsAsync() {
        Task {
            for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
                try? keychain.encryptKeyDB()
            }
        }
    }
}

/// Observable KeyCover snapshot for the (hidden) settings UI. All reads bottom out
/// at isKeyCoverEnabled, so everything reports disabled while hard-off.
@Observable class KeyCoverObservable {
    nonisolated(unsafe) static let shared = KeyCoverObservable()

    var keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
    var unlockedCount = KeyCover.shared.unlockedCount()
    var keychains = KeyCover.shared.listKeychains()

    var isKeyCoverUnlockingPromptShown = KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword
    ? false : KeyCoverPreferences.shared.keyCoverEnabled == .disabled
    ? false : KeyCoverPreferences.shared.promptForKeyCoverPasswordAtLaunch

    func update() {
        keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
        unlockedCount = KeyCover.shared.unlockedCount()
        keychains = KeyCover.shared.listKeychains()
    }
}

/// One app's ChainGuard key files: the legacy bare file plus the decrypted (.db)
/// and encrypted (.keyCover) variants. Uninstall sweeps all three via allFiles.
struct KeyCoverKey {
    static let encryptedKeyExtension = "keyCover"
    static let decryptedKeyExtension = "db"

    var appBundleID: String

    var allFiles: [URL] {
        [KeyCover.chainGuardPath.appendingPathComponent(appBundleID), decryptedKeyDB, encryptedKeyDB]
    }

    var decryptedKeyDB: URL {
        KeyCover.chainGuardPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        KeyCover.chainGuardPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    /// Encrypted iff the .keyCover ciphertext exists (plaintext .db means unlocked).
    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    /// Encrypts the .db via openssl AES-256-CBC, deletes the plaintext, refreshes UI.
    ///
    /// - Throws: Process/file failures.
    func encryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            // encrypt the db file
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            task.currentDirectoryPath = KeyCover.chainGuardPath.path
            task.arguments = ["enc", "-aes-256-cbc", "-A",
                                "-in", decryptedKeyDB.path,
                                "-out", encryptedKeyDB.path,
                                "-k", plainTextKey]
            try task.run()
            task.waitUntilExit()

            // delete the key dbs
            try deleteKeyDB()

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    /// Decrypts the .keyCover back to .db, deletes the ciphertext, refreshes UI.
    ///
    /// - Throws: Process/file failures.
    func decryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            // decrypt the zip file
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            task.arguments = ["enc", "-aes-256-cbc", "-A", "-d", "-in", encryptedKeyDB.path, "-out",
                              decryptedKeyDB.path,
                              "-k", plainTextKey]
            try task.run()
            task.waitUntilExit()
            // delete the encrypted key file
            try FileManager.default.removeItem(at: encryptedKeyDB)

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }
}

/// Master-password store (macOS login keychain). Rotating the password re-encrypts
/// every chain under the new key; removal decrypts everything first.
class KeyCoverPassword {
    nonisolated(unsafe) static let shared = KeyCoverPassword()

    let tag = "be.ophanim.masterkey"

    /// Stores a new master key: decrypts under the old key, replaces it in the login
    /// keychain, then re-encrypts all chains under the new key.
    ///
    /// - Parameter key: The new master password (plaintext, kept in memory).
    func setKeyCoverPassword(_ key: String) {
        // swiftlint: disable force_unwrapping
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecValueData as String: key.data(using: .utf8)!]
        // swiftlint: enable force_unwrapping
        // thank you apple very cool
        // Get the key
        let oldKey = getKeyCoverPassword()
        // if it is not nil, then we need to decrypt all the keychains
        if oldKey != nil {
            KeyCover.shared.keyCoverPlainTextKey = oldKey
            for keychain in KeyCover.shared.listKeychains() where keychain.chainEncryptionStatus {
                try? keychain.decryptKeyDB()
            }
            KeyCover.shared.keyCoverPlainTextKey = nil
            // Remove any existing master key
            SecItemDelete(query as CFDictionary)
        }

        // Store the master key in macOS keychain
        Task(priority: .userInitiated) {
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                print("Error storing master key in keychain: \(status)")
            }
        }

        KeyCover.shared.keyCoverPlainTextKey = key

        // Encrypts all keychains
        for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    /// Reads the master key from the login keychain.
    ///
    /// - Returns: The stored password, or nil when absent/undecodable.
    func getKeyCoverPassword() -> String? {
        // Get the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecReturnData as String: kCFBooleanTrue as Any,
                                    kSecMatchLimit as String: kSecMatchLimitOne]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// Removes KeyCover: decrypts everything, deletes the login-keychain entry.
    func removeKeyCoverPassword() {
        // Decrypt all key dbs
        for chain in KeyCover.shared.listKeychains() where chain.chainEncryptionStatus {
                try? chain.decryptKeyDB()
        }

        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        Task(priority: .userInitiated) {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess {
                print("Error removing master key from keychain: \(status)")
            }
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    /// Force-resets when the password is lost: deletes the keychain entry and nukes
    /// every encrypted chain (ciphertext without a key is useless). Refuses while a
    /// key is in memory (nothing is lost, so refuse rather than destroy).
    func forceResetKeyCoverPassword() {
        // If a key is in memory, don't do anything (prevent accidental deletion)
        if KeyCover.shared.keyCoverPlainTextKey != nil {
            return
        }
        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            print("Error removing master key from keychain: \(status)")
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        // Being a force reset, we have to nuke everything (because it's useless otherwise)
        for chain in KeyCover.shared.listKeychains() {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    /// Checks a candidate against the stored master key.
    ///
    /// - Parameter key: The candidate password.
    /// - Returns: Whether it matches.
    func validatePassword(_ key: String) -> Bool {
        return key == getKeyCoverPassword()
    }

    /// Generates a 32-char random password for the managed-key flow.
    ///
    /// - Returns: The generated password.
    func generateVerySecurePassword() -> String {
        // oh my god
        let length = 32
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+"
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }
}
