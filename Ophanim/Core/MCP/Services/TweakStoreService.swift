//
//  TweakStoreService.swift
//  Ophanim
//
//  Tweak-store reads: store resolution + entry inventory. Pure filesystem
//  reads behind injectable statics for tests.
//

import Foundation

/// Tweak-store reads: store resolution + entry inventory. Pure filesystem
/// reads behind injectable statics for tests.
enum TweakStoreService {
    /// Resolves an app's tweak store (custom folder when set, else the default).
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Returns: The store URL plus the custom path override (nil when default).
    static func store(bundleID bid: String) -> (store: URL, custom: String?) {
        let custom = SettingsStore.appSettings(bid)?.customTweakFolder
        return (Galgal.effectiveTweakStore(bundleIdentifier: bid, customPath: custom), custom)
    }

    /// Inventories a tweak store directory. Dotfiles are skipped; anything that
    /// is not a `.dylib`/`.framework` is reported with `willLoad: false` (the
    /// loader `dlopen`s only those two, so the rest is present but inert).
    ///
    /// - Parameter dir: The store (or subfolder) to list.
    /// - Parameter recursive: Whether to descend into subfolders.
    /// - Parameter prefix: The display-name prefix for recursion.
    /// - Returns: The entry dicts (`name`, `path`, `isFolder`, `isEnabled`,
    ///   `isFramework`, `isDylib`, `willLoad`).
    static func tweakEntries(in dir: URL, recursive: Bool, prefix: String) throws -> [[String: Any]] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [[String: Any]] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let isDisabled = name.hasSuffix(Galgal.disabledSuffix)
            let base = isDisabled ? String(name.dropLast(Galgal.disabledSuffix.count)) : name
            var entry: [String: Any] = [
                "name": prefix + name,
                "path": item.path,
                "isFolder": isDir,
                "isEnabled": !isDisabled,
                "isFramework": base.hasSuffix(".framework"),
                "isDylib": base.hasSuffix(".dylib")
            ]
            // Mirrors the loader: only .dylib and .framework are dlopen'd, so anything else in the
            // store is present but inert.
            entry["willLoad"] = !isDir && (base.hasSuffix(".dylib") || base.hasSuffix(".framework"))
            if isDisabled { entry["disabledName"] = name }
            out.append(entry)
            if isDir && recursive {
                out.append(contentsOf: try tweakEntries(in: item, recursive: true, prefix: prefix + name + "/"))
            }
        }
        return out
    }
}
