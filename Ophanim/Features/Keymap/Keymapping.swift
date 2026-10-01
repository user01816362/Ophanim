//
//  Keymapping.swift
//  Ophanim
//
//  Created by TheMoonThatRises on 9/15/25.
//

import Foundation
import UniformTypeIdentifiers

class Keymapping {
    static var keymappingDir: URL {
        let keymappingFolder = Galgal.ophanimContainer.appendingPathComponent("Keymapping")
        if !FileManager.default.fileExists(atPath: keymappingFolder.path) {
            do {
                try FileManager.default.createDirectory(at: keymappingFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return keymappingFolder
    }

    let info: AppInfo
    let baseKeymapURL: URL
    let configURL: URL

    let encoder: PropertyListEncoder

    var keymapConfig: KeymapConfig {
        get {
            do {
                let data = try Data(contentsOf: configURL)
                let map = try PropertyListDecoder().decode(KeymapConfig.self, from: data)
                return map
            } catch {
                print(error)
                return resetConfig()
            }
        }
        set {
            do {
                let data = try encoder.encode(newValue)
                try data.write(to: configURL)
            } catch {
                print(error)
            }
        }
    }

    init(_ info: AppInfo) {
        self.info = info

        self.baseKeymapURL = Keymapping.keymappingDir.appendingPathComponent(info.bundleIdentifier)
        self.configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        if !FileManager.default.fileExists(atPath: self.baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(at: self.baseKeymapURL,
                                                        withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        self.encoder = PropertyListEncoder()
        self.encoder.outputFormat = .xml

        self.reloadKeymapCache()

    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    public func reloadKeymapCache() {
        guard FileManager.default.fileExists(atPath: baseKeymapURL.path) else {
            return
        }

        do {
            let directoryContents = try FileManager.default
                .contentsOfDirectory(at: baseKeymapURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var keymaps: [URL] = []

            if directoryContents.count > 0 {
                for keymap in directoryContents where keymap.pathExtension.contains("plist") {
                    if !keymapConfig.keymapOrder.contains(keymap) {
                        keymapConfig.keymapOrder.append(keymap)
                    }

                    keymaps.append(keymap)
                }

                for keymap in keymapConfig.keymapOrder where !keymaps.contains(keymap) {
                    setKeymap(name: keymap.deletingPathExtension().lastPathComponent,
                              map: Keymap(bundleIdentifier: info.bundleIdentifier))
                }

                return
            }
        } catch {
            print("failed to get keymapping directory")
            Log.shared.error(error)
        }

        setKeymap(name: "default", map: Keymap(bundleIdentifier: info.bundleIdentifier))
        reloadKeymapCache()
    }

    public func getKeymap(name: String) -> Keymap {
        do {
            let data = try Data(contentsOf: constructKeymapPath(name: name))
            let map = try PropertyListDecoder().decode(Keymap.self, from: data)
            return map
        } catch {
            print(error)
            return reset(name: name)
        }
    }

    public func createEmptyKeymap(name: String) -> Bool {
        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))

        return hasKeymap(name: name)
    }

    private func setKeymap(name: String, map: Keymap) {
        let keymapPath = constructKeymapPath(name: name)

        do {
            let data = try encoder.encode(map)
            try data.write(to: keymapPath, options: .atomic)

            if !keymapConfig.keymapOrder.contains(keymapPath) {
                keymapConfig.keymapOrder.append(keymapPath)
            }
        } catch {
            print(error)
        }
    }

    /// Summary of a validated headless write (MCP set_keymap).
    struct ValidatedKeymapWrite {
        let url: URL?
        let buttons: Int
        let draggableButtons: Int
        let joysticks: Int
        let mouseAreas: Int
        let bundleIdentifier: String
        let wouldOverwrite: Bool
        let backupURL: URL?
    }

    /// Validated write for headless callers. Order: name gate (plain filename, no
    /// traversal) → bundle binding (enforced unless explicitly allowed) → backup →
    /// atomic write through the shared setKeymap path. dryRun computes everything and
    /// writes nothing. Throws with a description; never resets-and-blanks on failure.
    func writeValidatedKeymap(name: String, map: Keymap,
                              allowBundleMismatch: Bool, dryRun: Bool) throws -> ValidatedKeymapWrite {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw NSError(domain: "be.ophanim.Ophanim", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "invalid keymap name '\(name)': plain filename, no slashes"])
        }
        guard allowBundleMismatch || map.bundleIdentifier == info.bundleIdentifier else {
            throw NSError(domain: "be.ophanim.Ophanim", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "keymap bundle '\(map.bundleIdentifier)' does not match app "
                                        + "'\(info.bundleIdentifier)'; pass allowBundleMismatch:true to file it anyway"])
        }
        let target = constructKeymapPath(name: name)
        let wouldOverwrite = FileManager.default.fileExists(atPath: target.path)
        let summary = ValidatedKeymapWrite(url: dryRun ? nil : target,
                                           buttons: map.buttonModels.count,
                                           draggableButtons: map.draggableButtonModels.count,
                                           joysticks: map.joystickModel.count,
                                           mouseAreas: map.mouseAreaModel.count,
                                           bundleIdentifier: map.bundleIdentifier,
                                           wouldOverwrite: wouldOverwrite,
                                           backupURL: nil)
        if dryRun { return summary }
        var backup: URL? = nil
        if wouldOverwrite {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            backup = baseKeymapURL.appendingPathComponent("\(name)-\(f.string(from: Date())).bak.plist")
            try FileManager.default.copyItem(at: target, to: backup!)
        }
        setKeymap(name: name, map: map)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw NSError(domain: "be.ophanim.Ophanim", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "keymap write failed for '\(name)'"])
        }
        return ValidatedKeymapWrite(url: target, buttons: summary.buttons,
                                    draggableButtons: summary.draggableButtons,
                                    joysticks: summary.joysticks, mouseAreas: summary.mouseAreas,
                                    bundleIdentifier: summary.bundleIdentifier,
                                    wouldOverwrite: wouldOverwrite, backupURL: backup)
    }

    public func renameKeymap(prevName: String, newName: String) -> Bool {
        let oldPath = constructKeymapPath(name: prevName)
        let newPath = constructKeymapPath(name: newName)

        if let oldKeymapIndex = keymapConfig.keymapOrder.firstIndex(of: oldPath) {
            do {
                try FileManager.default.moveItem(at: oldPath, to: newPath)

                keymapConfig.keymapOrder[oldKeymapIndex] = newPath

                return true
            } catch {
                Log.shared.error(error)
                return false
            }
        } else {
            print("could not find keymap with name: \(prevName)")
            return false
        }
    }

    public func deleteKeymap(name: String) -> Bool {
        let keymapURL = constructKeymapPath(name: name)

        if let keymapIndex = keymapConfig.keymapOrder.firstIndex(of: keymapURL) {
            do {
                try FileManager.default.trashItem(at: keymapURL, resultingItemURL: nil)

                keymapConfig.keymapOrder.remove(at: keymapIndex)

                return true
            } catch {
                Log.shared.error(error)
                return false
            }
        } else {
            print("could not find keymap with name: \(name)")
            return false
        }
    }

    public func hasKeymap(name: String) -> Bool {
        keymapConfig.keymapOrder.contains(constructKeymapPath(name: name))
    }

    @discardableResult
    public func reset(name: String) -> Keymap {
        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))
        return getKeymap(name: name)
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")

        keymapConfig = KeymapConfig(defaultKm: defaultURL,
                                    keymapOrder: [defaultURL])

        return keymapConfig
    }

    public func importKeymap(name: String, success: @escaping (Bool) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = true
        openPanel.allowedContentTypes = [UTType(exportedAs: "be.ophanim.Ophanim-galgalmap")]
        openPanel.title = NSLocalizedString("hostedapp.importKm", comment: "")

        // runModal (synchronous, main thread): same UX as begin, no @Sendable closure.
        if openPanel.runModal() == .OK {
                do {
                    if let selectedPath = openPanel.url {
                        let data = try Data(contentsOf: selectedPath)
                        let importedKeymap = try PropertyListDecoder().decode(Keymap.self, from: data)
                        if importedKeymap.bundleIdentifier == self.info.bundleIdentifier {
                            self.setKeymap(name: name, map: importedKeymap)
                            success(true)
                        } else {
                            if self.differentBundleIdKeymapAlert() {
                                self.setKeymap(name: name, map: importedKeymap)
                                success(true)
                            } else {
                                success(false)
                            }
                        }
                    }
                } catch {
                    if let selectedPath = openPanel.url {
                        if let keymap = LegacySettings.convertLegacyKeymapFile(selectedPath) {
                            if keymap.bundleIdentifier == self.info.bundleIdentifier {
                                self.setKeymap(name: name, map: keymap)
                                success(true)
                            } else {
                                if self.differentBundleIdKeymapAlert() {
                                    self.setKeymap(name: name, map: keymap)
                                    success(true)
                                } else {
                                    success(false)
                                }
                            }
                        } else {
                            success(false)
                        }
                    }
                }
                openPanel.close()
        }
    }

    public func exportKeymap(name: String) {
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("hostedapp.exportKm", comment: "")
        savePanel.nameFieldLabel = NSLocalizedString("hostedapp.exportKmPanel.fieldLabel", comment: "")
        savePanel.nameFieldStringValue = info.displayName
        savePanel.allowedContentTypes = [UTType(exportedAs: "be.ophanim.Ophanim-galgalmap")]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        if savePanel.runModal() == .OK {
                do {
                    if let selectedPath = savePanel.url {
                        let data = try self.encoder.encode(self.getKeymap(name: name))
                        try data.write(to: selectedPath)
                        selectedPath.openInFinder()
                    }
                } catch {
                    savePanel.close()
                    Log.shared.error(error)
                }
                savePanel.close()
        }
    }

    private func differentBundleIdKeymapAlert() -> Bool {
        Log.confirm(question: NSLocalizedString("alert.differentBundleIdKeymap.message", comment: ""),
                    text: NSLocalizedString("alert.differentBundleIdKeymap.text", comment: ""),
                    style: .warning,
                    ok: NSLocalizedString("button.Proceed", comment: ""),
                    cancel: NSLocalizedString("button.Cancel", comment: ""))
    }
}
