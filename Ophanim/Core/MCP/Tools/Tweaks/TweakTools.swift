//
//  TweakTools.swift
//  Ophanim
//
//  Tweak / injected-library management tools. Thin wrappers over Galgal's
//  own statics — the same ones the tweak library pane drives — never a
//  parallel store layout.
//

import Foundation

/// Tweak / injected-library management tools. Thin wrappers over Galgal's
/// own statics — the same ones the tweak library pane drives — never a
/// parallel store layout.
///
/// Run `inspect_tweak` before `add_tweak`: a slice the engine cannot load is
/// refused before copying, not after.
enum TweakTools {

    // MARK: - Reads

    /// Lists an app's tweak store entries (dylib/framework/folder, enabled state).
    ///
    /// - Parameter args: `bundleID` (required); `recursive` (default false:
    ///   top level only).
    /// - Returns: JSON with the `store` path, `count`, and the `tweaks` entries.
    static func listTweaks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        let recursive = (args["recursive"] as? Bool) ?? false
        let store = TweakStoreService.store(bundleID: bid).store
        let entries = try TweakStoreService.tweakEntries(in: store, recursive: recursive, prefix: "")
        return try ToolRouter.json(["bundleID": bid, "store": store.path, "count": entries.count, "tweaks": entries])
    }

    /// Reports loadability + Mach-O facts for a tweak file. Run before adding.
    ///
    /// - Parameter args: `path` (required filesystem path, `~` expanded).
    /// - Returns: The `Macho.inspect` JSON (`loadable` + facts or refusal `reason`).
    /// - Throws: `ToolRouter.bail` when `path` is missing (inspect errors propagate).
    static func inspectTweak(_ args: [String: Any]) throws -> String {
        guard let path = args["path"] as? String, !path.isEmpty else { throw ToolRouter.bail("path is required") }
        let url = ToolRouter.expandedURL(path)
        return try ToolRouter.json(try Macho.inspect(url))
    }

    // MARK: - Mutations

    /// Copies a tweak into the store after a loadability check. Destructive:
    /// dryRun previews by default.
    ///
    /// A slice the engine cannot load is refused before copying rather than
    /// after; an existing name needs `replace: true` to overwrite.
    ///
    /// - Parameter args: `bundleID` + `path` (required); `replace` (default
    ///   false); `dryRun: false` copies.
    /// - Returns: Dry-run JSON with `source`/`destination`/`wouldReplace`, or
    ///   confirmation with the `added` path.
    /// - Throws: `ToolRouter.bail` when `path` is missing, names no file, the
    ///   app is not installed, the slice is not loadable, or the name exists
    ///   without `replace: true`.
    static func addTweak(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let path = args["path"] as? String, !path.isEmpty else { throw ToolRouter.bail("path is required") }
        let source = ToolRouter.expandedURL(path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ToolRouter.bail("no such file: \(source.path)")
        }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        // Refuse a slice the engine cannot load, before copying rather than after.
        let verdict = try Macho.inspect(source)
        if verdict["loadable"] as? Bool == false {
            throw ToolRouter.bail("this file cannot be loaded by the engine: "
                + "\(verdict["reason"] as? String ?? "unsupported slice")")
        }
        let (store, custom) = TweakStoreService.store(bundleID: bid)
        let destination = store.appendingPathComponent(source.lastPathComponent)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists && (args["replace"] as? Bool) != true {
            throw ToolRouter.bail("a tweak named '\(source.lastPathComponent)' already exists; pass replace:true to overwrite")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "source": source.path,
                                 "destination": destination.path, "wouldReplace": exists,
                                 "loadable": true])
        }
        try Galgal.addTweakItem(at: source, bundleIdentifier: bid,
                                appExecutable: exe, customPath: custom)
        return try ToolRouter.json(["bundleID": bid, "added": destination.path, "replaced": exists])
    }

    /// Renames a tweak inside the store (and re-syncs the app). Destructive:
    /// dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `from` + `to` (required, store-relative);
    ///   `dryRun: false` renames.
    /// - Returns: Dry-run JSON with resolved `from`/`to` paths, or confirmation
    ///   with the `moved` pair.
    /// - Throws: `ToolRouter.bail` when names are missing, the source is absent,
    ///   the destination exists, or the app is not installed.
    static func moveTweak(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let from = args["from"] as? String, !from.isEmpty else { throw ToolRouter.bail("from is required") }
        guard let to = args["to"] as? String, !to.isEmpty else { throw ToolRouter.bail("to is required") }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let (store, custom) = TweakStoreService.store(bundleID: bid)
        let source = store.appendingPathComponent(from)
        let destination = store.appendingPathComponent(to)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ToolRouter.bail("no such tweak: \(from)")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolRouter.bail("'\(to)' already exists")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "from": source.path, "to": destination.path])
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        try? Galgal.syncUserDylibs(bundleIdentifier: bid, into: exe, customPath: custom)
        return try ToolRouter.json(["bundleID": bid, "moved": [source.path, destination.path]])
    }

    /// Removes a tweak from the store (and re-syncs the app). Destructive:
    /// dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `name` (required, store-relative);
    ///   `dryRun: false` removes.
    /// - Returns: Dry-run JSON with `wouldRemove`, or confirmation with `removed`.
    /// - Throws: `ToolRouter.bail` when `name` is missing or absent, or the app
    ///   is not installed.
    static func removeTweak(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let (store, custom) = TweakStoreService.store(bundleID: bid)
        let target = store.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolRouter.bail("no such tweak: \(name)")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "wouldRemove": target.path])
        }
        try FileManager.default.removeItem(at: target)
        try? Galgal.syncUserDylibs(bundleIdentifier: bid, into: exe, customPath: custom)
        return try ToolRouter.json(["bundleID": bid, "removed": target.path])
    }

    /// Enables/disables a tweak via the `.disabled` convention (and re-syncs
    /// the app). Destructive: dryRun previews by default.
    ///
    /// Accepts the display name with or without the `.disabled` suffix, so a
    /// caller that read the name from `list_tweaks` can pass it straight back.
    ///
    /// - Parameter args: `bundleID` + `name` (required); `enabled` (required
    ///   boolean); `dryRun: false` applies.
    /// - Returns: Dry-run JSON, or confirmation with `name` and `enabled`.
    /// - Throws: `ToolRouter.bail` when `name`/`enabled` is missing, names no
    ///   tweak, or the app is not installed.
    static func setTweakEnabled(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        guard let enabled = args["enabled"] as? Bool else { throw ToolRouter.bail("enabled (boolean) is required") }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let (store, custom) = TweakStoreService.store(bundleID: bid)
        // Accept the display name with or without the .disabled suffix, so a caller that read
        // the name from list_tweaks can pass it straight back.
        let base = name.hasSuffix(Galgal.disabledSuffix)
            ? String(name.dropLast(Galgal.disabledSuffix.count)) : name
        let item = TweakItem(fileUrl: store.appendingPathComponent(base), isFolder: false,
                             isFramework: base.hasSuffix(".framework"),
                             isTweak: base.hasSuffix(".dylib"), isEnabled: enabled)
        guard FileManager.default.fileExists(atPath: item.fileUrl.path)
                || FileManager.default.fileExists(atPath: item.fileUrl.path + Galgal.disabledSuffix) else {
            throw ToolRouter.bail("no such tweak: \(name)")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "name": base, "enabled": enabled])
        }
        try Galgal.setTweakEnabled(item: item, enabled: enabled, bundleIdentifier: bid,
                                   appExecutable: exe, customPath: custom)
        return try ToolRouter.json(["bundleID": bid, "name": base, "enabled": enabled])
    }

    /// Creates, renames, or removes a tweak subfolder. Destructive: dryRun
    /// previews by default.
    ///
    /// - Parameter args: `bundleID` + `action` (`create`/`rename`/`remove`) +
    ///   `name` (required); `newName` (required for `rename`);
    ///   `dryRun: false` applies.
    /// - Returns: Dry-run JSON, or confirmation with the `created`/`renamed`/
    ///   `removed` path.
    /// - Throws: `ToolRouter.bail` when `action`/`name` is missing or unknown,
    ///   `newName` is missing for `rename`, or the folder is absent.
    static func tweakFolder(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let action = args["action"] as? String else { throw ToolRouter.bail("action is required") }
        guard let name = args["name"] as? String, !name.isEmpty else { throw ToolRouter.bail("name is required") }
        let (store, custom) = TweakStoreService.store(bundleID: bid)
        let folder = store.appendingPathComponent(name)
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "action": action, "path": folder.path])
        }
        switch action {
        case "create":
            try Galgal.createNewSubfolder(named: name, bundleIdentifier: bid, customPath: custom)
            return try ToolRouter.json(["bundleID": bid, "created": folder.path])
        case "rename":
            guard let newName = args["newName"] as? String, !newName.isEmpty else {
                throw ToolRouter.bail("newName is required for action=rename")
            }
            let destination = store.appendingPathComponent(newName)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw ToolRouter.bail("no such folder: \(name)")
            }
            try FileManager.default.moveItem(at: folder, to: destination)
            return try ToolRouter.json(["bundleID": bid, "renamed": [folder.path, destination.path]])
        case "remove":
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw ToolRouter.bail("no such folder: \(name)")
            }
            try FileManager.default.removeItem(at: folder)
            return try ToolRouter.json(["bundleID": bid, "removed": folder.path])
        default:
            throw ToolRouter.bail("action must be create, rename or remove; got '\(action)'")
        }
    }

    /// Re-syncs the tweak store into the app binary. No dryRun gate: sync is
    /// convergent (rebuilds Frameworks/UserPlugins from the store), idempotent
    /// when already in sync.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `synced: true` and the `failed` list.
    /// - Throws: `ToolRouter.bail` when the app is not installed or the sync fails.
    static func resyncTweaks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let custom = TweakStoreService.store(bundleID: bid).custom
        do {
            try Galgal.syncUserDylibs(bundleIdentifier: bid, into: exe, customPath: custom)
            return try ToolRouter.json(["bundleID": bid, "synced": true, "failed": [String]()])
        } catch {
            throw ToolRouter.bail("resync failed: \(error.localizedDescription)")
        }
    }
}
