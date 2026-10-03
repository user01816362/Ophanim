//
//  Galgal.swift
//  Ophanim
//
//  Galgal runtime + tweak-store wiring: framework install, dylib injection,
//  and the tweak library pane's statics (also driven headless by TweakTools).
//

import Foundation
import injection

/// One tweak-store row: a dylib, framework, or folder with its enabled state.
public struct TweakItem: Hashable, Identifiable, Sendable {
    public var id: URL { fileUrl }
    public let fileUrl: URL
    public let isFolder: Bool
    public let isFramework: Bool
    public let isTweak: Bool
    public let isEnabled: Bool

    public var displayName: String {
        let name = fileUrl.lastPathComponent
        return isEnabled ? name : String(name.dropLast(Galgal.disabledSuffix.count))
    }
}

class Galgal {
    private static let frameworksURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
    private static let galgalFramework = frameworksURL
        .appendingPathComponent("Galgal")
        .appendingPathExtension("framework")
    private static let galgalPath = galgalFramework
        .appendingPathComponent("Galgal")
    private static let galgalInterfacePath = galgalFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("GalgalInterface")
        .appendingPathExtension("bundle")
    private static let bundledGalgalFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("Galgal")
        .appendingPathExtension("framework")

    // Sibling-injection agent dylib: installed in ~/Library/Frameworks alongside Galgal.framework,
    // bundled in the app's Contents/Frameworks. Injected as a 2nd LC_LOAD_DYLIB when a hosted app
    // is set to the .sibling injection strategy.
    private static let agentPath = frameworksURL.appendingPathComponent("OphanimAgent.dylib")
    private static let bundledAgent = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("OphanimAgent.dylib")

    public static var ophanimContainer: URL {
        let ophanimPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("be.ophanim.Ophanim")
        if !FileManager.default.fileExists(atPath: ophanimPath.path) {
            do {
                try FileManager.default.createDirectory(at: ophanimPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return ophanimPath
    }

    static func installOnSystem() {
        Task(priority: .background) {
            do {
                Log.shared.log("Installing Galgal")

                // Check if Frameworks folder exists, if not, create it
                if !FileManager.default.fileExists(atPath: frameworksURL.path) {
                    try FileManager.default.createDirectory(
                        atPath: frameworksURL.path,
                        withIntermediateDirectories: true,
                        attributes: [:])
                }

                // Replace any installed version with the one bundled in Ophanim.
                Log.shared.log("Copying Galgal to Frameworks")
                try FileManager.default.replaceItem(at: galgalFramework, with: bundledGalgalFramework)

                // Stage the sibling-injection agent dylib next to the framework.
                installAgentOnSystem()
            } catch {
                Log.shared.error(error)
            }
        }
    }

    static func installInIPA(_ exec: URL) async throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: galgalPath.path,
                           finishHandle: { result in
            if result {
                do {
                    try installPluginInIPA(exec.deletingLastPathComponent())
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func installPluginInIPA(_ payload: URL) throws {
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: bundledGalgalFramework, includingPropertiesForKeys: [])
        for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
            _ = try copyAsset(target: payload,
                              directoryName: localizationDirectory.lastPathComponent,
                              component: "Galgal", pathExtension: "strings")
        }

        let bundledGalgalResources = bundledGalgalFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: bundledGalgalResources.path) {
            let allFiles = try FileManager.default.contentsOfDirectory(
                at: bundledGalgalResources, includingPropertiesForKeys: [])
            for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
                _ = try copyAsset(source: bundledGalgalResources,
                                  target: payload,
                                  directoryName: localizationDirectory.lastPathComponent,
                                  component: "Galgal", pathExtension: "strings")
            }
        }

        let bundleTarget = try copyAsset(target: payload, directoryName: "PlugIns",
                                         component: "GalgalInterface", pathExtension: "bundle")
        try bundleTarget.fixExecutable()
        try Shell.signMacho(bundleTarget)
    }

    static func copyAsset(source: URL = bundledGalgalFramework, target: URL, directoryName: String,
                          component: String, pathExtension: String) throws -> URL {
        let directory = target.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)

        let source = source
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }

    static func injectInIPA(_ exec: URL, payload: URL) throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: "@executable_path/Frameworks/Galgal.dylib",
                           finishHandle: { result in
            if result {
                Task(priority: .background) {
                    do {
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("Frameworks").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("Frameworks"),
                                withIntermediateDirectories: true)
                        }

                        let libraryTarget = payload.appendingPathComponent("Frameworks")
                            .appendingPathComponent("Galgal")
                            .appendingPathExtension("dylib")

                        let tools = bundledGalgalFramework
                            .appendingPathComponent("Galgal")

                        try FileManager.default.replaceItem(at: libraryTarget, with: tools)

                        try libraryTarget.fixExecutable()
                        try installPluginInIPA(payload)
                    } catch {
                        Log.shared.error(error)
                    }
                }
            }
        })
    }

    static func removeFromApp(_ exec: URL) async {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: galgalPath.path,
                           finishHandle: { result in
            if result {
                do {
                    let pluginUrl = exec.deletingLastPathComponent()
                        .appendingPathComponent("PlugIns")
                        .appendingPathComponent("GalgalInterface")
                        .appendingPathExtension("bundle")

                    if FileManager.default.fileExists(atPath: pluginUrl.path) {
                        try FileManager.default.removeItem(at: pluginUrl)
                    }
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    /// Walk a Mach-O's load commands and report whether any LC_LOAD_DYLIB points at `dylibPath`.
    private static func execLinksDylib(atURL url: URL, dylibPath: String) throws -> Bool {
        var binary = try Data(contentsOf: url)
        try Macho.stripBinary(&binary)
        var result = false
        try _ = Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? { swapLoadCommand($0, $1) } : nil)
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCommand = binary.extract(dylib_command.self, offset: offset,
                                                  swap: shouldSwap ? { swapDylibCommand($0, $1) } : nil)

                let dylibName = String(data: binary,
                                       offset: offset,
                                       commandSize: Int(dylibCommand.cmdsize),
                                       loadCommandString: dylibCommand.dylib.name)
                if dylibName == dylibPath {
                    result = true
                    return true
                }
            }
            return false
        }
        return result
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        try execLinksDylib(atURL: url, dylibPath: galgalPath.esc)
    }

    static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: galgalPath.path)
            && FileManager.default.fileExists(atPath: galgalInterfacePath.path)
            && Macho.isMachoValidArch(galgalPath)
    }

    // MARK: - Sibling agent injection (OphanimAgent.dylib)

    /// Copy the bundled agent dylib next to the system Galgal framework so injected apps can load it.
    static func installAgentOnSystem() {
        guard FileManager.default.fileExists(atPath: bundledAgent.path) else { return }
        do {
            try FileManager.default.replaceItem(at: agentPath, with: bundledAgent)
        } catch {
            Log.shared.error(error)
        }
    }

    /// Add a 2nd LC_LOAD_DYLIB pointing at the agent, then re-sign. Used for the .sibling strategy.
    ///
    /// Fire-and-forget injection + sign (errors log): callers poll
    /// `agentInstalledInExec` to confirm the load command landed.
    ///
    /// - Parameter exec: The app executable to patch.
    static func installAgentInIPA(_ exec: URL) {
        installAgentOnSystem()
        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: agentPath.path,
                           finishHandle: { result in
            if result {
                do { try Shell.signApp(exec) } catch { Log.shared.error(error) }
            }
        })
    }

    /// Remove the agent load command (when switching back to embedded), then re-sign.
    ///
    /// Fire-and-forget like the install path: callers poll `agentInstalledInExec`.
    ///
    /// - Parameter exec: The app executable to patch.
    static func removeAgentFromApp(_ exec: URL) {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: agentPath.path,
                           finishHandle: { result in
            if result {
                do { try Shell.signApp(exec) } catch { Log.shared.error(error) }
            }
        })
    }

    /// Whether the agent load command is present in an executable.
    ///
    /// - Parameter url: The app executable to inspect.
    /// - Returns: True when the agent dylib is linked.
    /// - Throws: When the binary cannot even be read (itself an answer: the
    ///   desired state is unreachable/unreached).
    static func agentInstalledInExec(atURL url: URL) throws -> Bool {
        try execLinksDylib(atURL: url, dylibPath: agentPath.esc)
    }

	static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return try Shell.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else if error.localizedDescription.contains("code object is not signed at all") {
                // IPA not signed
                return ""
            } else {
                throw error
            }
        }
	}

    // MARK: - User custom plugins & tweak folders

    /// Suffix marking a disabled tweak (file stays in the store, loader skips it).
    public static let disabledSuffix = ".disabled"

    /// The default per-app tweak store (no custom folder).
    ///
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Returns: The store URL (may not exist yet).
    public static func defaultTweakStore(bundleIdentifier: String) -> URL {
        tweakStoresRoot.appendingPathComponent(bundleIdentifier)
    }

    /// The directory that holds every app's tweak store, one subdirectory per bundle identifier.
    /// Anything that enumerates or prunes per-app state must start here, so the layout is defined
    /// in exactly one place.
    public static var tweakStoresRoot: URL {
        ophanimContainer
            .appendingPathComponent("Galgal")
            .appendingPathComponent("UserPlugins")
    }

    /// Resolves the store an app actually uses: the custom folder when set and a
    /// directory, else the default store.
    ///
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter customPath: The custom tweak folder override (nil/empty/missing
    ///   falls back to default).
    /// - Returns: The effective store URL.
    public static func effectiveTweakStore(bundleIdentifier: String, customPath: String?) -> URL {
        if let customPath = customPath, !customPath.isEmpty {
            let customURL = URL(fileURLWithPath: customPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: customURL.path, isDirectory: &isDir), isDir.boolValue {
                return customURL
            }
        }
        return defaultTweakStore(bundleIdentifier: bundleIdentifier)
    }

    public static func tweakItems(bundleIdentifier: String, customPath: String?) -> [TweakItem] {
        let store = effectiveTweakStore(bundleIdentifier: bundleIdentifier, customPath: customPath)
        guard let files = try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) else {
            return []
        }
        var items: [TweakItem] = []
        for file in files {
            let fileName = file.lastPathComponent
            if fileName.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
            let isEnabled = !fileName.hasSuffix(disabledSuffix)
            let baseName = isEnabled ? fileName : String(fileName.dropLast(disabledSuffix.count))
            let isFramework = isDir.boolValue && baseName.hasSuffix(".framework")
            // Exactly what syncUserDylibs ships: `.dylib` files and `.framework` bundles. A bare
            // Mach-O also matches UTType.unixExecutable, but sync skips it - listing it as a
            // tweak would show something enabled that can never reach the app, so it stays a
            // plain file row instead.
            let isTweak = !isDir.boolValue && baseName.hasSuffix(".dylib")
            let isFolder = isDir.boolValue && !isFramework

            items.append(TweakItem(fileUrl: file,
                                   isFolder: isFolder,
                                   isFramework: isFramework,
                                   isTweak: isTweak,
                                   isEnabled: isEnabled))
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Toggles a tweak via the `.disabled` rename, then re-syncs the app.
    /// Idempotent: an already-correct suffix is a no-op rename, sync still runs.
    ///
    /// - Parameter item: The tweak row (suffix-insensitive; see `TweakTools.setTweakEnabled`).
    /// - Parameter enabled: The desired state.
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter appExecutable: The app executable to re-sync into.
    /// - Parameter customPath: The custom tweak folder override.
    /// - Throws: Filesystem errors; sync failures propagate.
    public static func setTweakEnabled(item: TweakItem,
                                       enabled: Bool,
                                       bundleIdentifier: String,
                                       appExecutable: URL,
                                       customPath: String?) throws {
        let currentUrl = item.fileUrl
        let currentName = currentUrl.lastPathComponent
        if enabled && currentName.hasSuffix(disabledSuffix) {
            let newName = String(currentName.dropLast(disabledSuffix.count))
            let targetUrl = currentUrl.deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(at: currentUrl, to: targetUrl)
        } else if !enabled && !currentName.hasSuffix(disabledSuffix) {
            let newName = currentName + disabledSuffix
            let targetUrl = currentUrl.deletingLastPathComponent().appendingPathComponent(newName)
            try FileManager.default.moveItem(at: currentUrl, to: targetUrl)
        }
        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable, customPath: customPath)
    }

    /// Copies a tweak into the store (arch-checked + converted for dylibs),
    /// then re-syncs the app. Non-tweak files (bare Mach-Os, text, aliases)
    /// are rejected: they would list but never load.
    ///
    /// - Parameter sourceURL: The file to copy in.
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter appExecutable: The app executable to re-sync into.
    /// - Parameter customPath: The custom tweak folder override.
    /// - Throws: `OphanimError.invalidUserDylib` for rejected files or bad-arch
    ///   dylibs (partial copy removed); sync failures propagate.
    public static func addTweakItem(at sourceURL: URL,
                                    bundleIdentifier: String,
                                    appExecutable: URL,
                                    customPath: String?) throws {
        let store = effectiveTweakStore(bundleIdentifier: bundleIdentifier, customPath: customPath)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        // Accept only what the pipeline handles: `.dylib` files (arch-checked below),
        // `.framework` bundles, and directories (tweak folders scanned recursively). Anything
        // else - a bare Mach-O, a text file, an alias - would sit in the store forever: listed
        // but never synced, never loaded. Reject it at the door with the existing error.
        var isSourceDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isSourceDir),
              isSourceDir.boolValue
                || sourceURL.pathExtension == "dylib"
                || sourceURL.pathExtension == "framework" else {
            throw OphanimError.invalidUserDylib
        }

        let target = store.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: sourceURL, to: target)

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        if !isDir.boolValue && target.pathExtension == "dylib" {
            do {
                if !(try Macho.isMachoValidArch(target)) {
                    try Macho.convertMacho(target)
                }
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw OphanimError.invalidUserDylib
            }
        }

        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", target.path)
        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable, customPath: customPath)
    }

    /// Creates a tweak subfolder (same name rules as container profiles).
    ///
    /// - Parameter name: The folder name (no separators/traversal).
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter customPath: The custom tweak folder override.
    /// - Throws: `OphanimError.invalidFolderName` on bad names.
    public static func createNewSubfolder(named name: String,
                                          bundleIdentifier: String,
                                          customPath: String?) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              !trimmed.contains("..") else {
            throw OphanimError.invalidFolderName
        }
        let store = effectiveTweakStore(bundleIdentifier: bundleIdentifier, customPath: customPath)
        let subfolder = store.appendingPathComponent(trimmed)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
    }

    /// Removes a tweak from the store, then re-syncs the app. Missing files are
    /// tolerated (sync still runs, converging the binary to the store).
    ///
    /// - Parameter item: The tweak row to remove.
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter appExecutable: The app executable to re-sync into.
    /// - Parameter customPath: The custom tweak folder override.
    /// - Throws: Sync failures propagate.
    public static func removeTweakItem(item: TweakItem,
                                       bundleIdentifier: String,
                                       appExecutable: URL,
                                       customPath: String?) throws {
        if FileManager.default.fileExists(atPath: item.fileUrl.path) {
            try FileManager.default.removeItem(at: item.fileUrl)
        }
        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable, customPath: customPath)
    }

    /// Resync user dylibs into the app's Frameworks/UserPlugins directory and sign them.
    /// Rebuilds the target dir from the store (enabled dylibs/frameworks only,
    /// folders scanned recursively to depth 8); a missing store converges to empty.
    ///
    /// - Parameter bundleIdentifier: The app's bundle identifier.
    /// - Parameter appExecutable: The app executable whose sibling Frameworks dir
    ///   receives the synced libraries.
    /// - Parameter customPath: The custom tweak folder override.
    /// - Throws: Filesystem/sign failures propagate.
    public static func syncUserDylibs(bundleIdentifier: String,
                                      into appExecutable: URL,
                                      customPath: String? = nil) throws {
        let targetDirectory = appExecutable.deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("UserPlugins")

        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            try FileManager.default.removeItem(at: targetDirectory)
        }

        let store = effectiveTweakStore(bundleIdentifier: bundleIdentifier, customPath: customPath)
        guard FileManager.default.fileExists(atPath: store.path) else { return }

        var dylibsToSync: [URL] = []
        var frameworksToSync: [URL] = []
        var visitedCanonicalPaths = Set<String>()

        func scanDirectory(_ dir: URL, depth: Int = 0) {
            guard depth <= 8 else { return }
            let canonical = dir.resolvingSymlinksInPath().path
            guard visitedCanonicalPaths.insert(canonical).inserted else { return }

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { return }

            for file in contents {
                let name = file.lastPathComponent
                if name.hasPrefix(".") || name.hasSuffix(disabledSuffix) { continue }

                let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDir = values?.isDirectory == true

                if isDir {
                    if name.hasSuffix(".framework") {
                        frameworksToSync.append(file)
                    } else {
                        if values?.isSymbolicLink == true {
                            let resolved = file.resolvingSymlinksInPath()
                            if visitedCanonicalPaths.contains(resolved.path) { continue }
                        }
                        scanDirectory(file, depth: depth + 1)
                    }
                } else if name.hasSuffix(".dylib") {
                    // Only what the loader will actually load. This previously also accepted
                    // anything conforming to UTType.unixExecutable, but GalgalLoader.m dlopens
                    // only `.dylib` and `.framework` - so a bare Mach-O was copied, re-signed
                    // and shipped into the app, appeared in the store as present, and was never
                    // loaded. Rejecting it here is honest; silently accepting it was not.
                    dylibsToSync.append(file)
                }
            }
        }

        scanDirectory(store, depth: 0)

        if dylibsToSync.isEmpty && frameworksToSync.isEmpty { return }

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let storePrefix = store.standardizedFileURL.path + "/"

        for source in dylibsToSync {
            let sourcePath = source.standardizedFileURL.path
            let relativePath: String
            if sourcePath.hasPrefix(storePrefix) {
                relativePath = String(sourcePath.dropFirst(storePrefix.count))
            } else {
                relativePath = source.lastPathComponent
            }
            let target = targetDirectory.appendingPathComponent(relativePath)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", target.path)
                try target.fixExecutable()
                try Shell.signMacho(target)
            } catch {
                Log.shared.error("Failed to sync dylib \(source.lastPathComponent): \(error)")
                try? FileManager.default.removeItem(at: target)
            }
        }

        for source in frameworksToSync {
            let sourcePath = source.standardizedFileURL.path
            let relativePath: String
            if sourcePath.hasPrefix(storePrefix) {
                relativePath = String(sourcePath.dropFirst(storePrefix.count))
            } else {
                relativePath = source.lastPathComponent
            }
            let target = targetDirectory.appendingPathComponent(relativePath)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", target.path)
                try target.fixExecutable()
                try Shell.signMacho(target)
            } catch {
                Log.shared.error("Failed to sync framework \(source.lastPathComponent): \(error)")
                try? FileManager.default.removeItem(at: target)
            }
        }
    }
}
