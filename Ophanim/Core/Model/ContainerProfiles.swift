//
//  ContainerProfiles.swift
//  Ophanim
//
//  Multiple named data containers per hosted app, selected at launch.
//  Directory swaps around the OS-owned live path; guards refuse while running.
//

import AppKit
import Foundation

/// Multiple named data containers per hosted app, selected at launch.
///
/// macOS gives every hosted app exactly one live sandbox (`~/Library/Containers/<bid>`), so
/// profiles are implemented as directory swaps around that OS-owned path - no container daemon,
/// no bookmarks, no re-registration. Each profile is a full copy of a container tree stored
/// under Ophanim's own container; switching moves the live tree aside and the chosen profile
/// into place (same-volume renames, no byte copies). The app is never touched: only data moves.
///
/// Guards, all load-bearing because this moves user data:
/// - switching, deleting, and restoring all refuse while the app runs (open files + a moved
///   tree = corruption);
/// - deleting the active profile is refused (it would strand the live tree from its backup);
/// - names use the same rules as tweak subfolders (no separators, no traversal);
/// - every mutating op throws with the untouched state left behind on failure (move-then-move
///   ordering: the live tree is parked before the profile moves in, so a mid-swap failure
///   still has both trees on disk, just parked);
/// - the launch hook below never throws: any failure logs and launch proceeds with whatever
///   live container exists, which is exactly the original behavior.
struct ContainerProfiles {

    /// Root holding one subdirectory per bundle identifier, each holding its profiles.
    /// Wiped with app data on uninstall (see clearExternalCache), so a reinstall never
    /// inherits another install's profiles.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The profile store root.
    static func storeRoot(bundleID: String) -> URL {
        Galgal.ophanimContainer
            .appendingPathComponent("Containers")
            .appendingPathComponent(bundleID)
    }

    /// The OS-owned live container path for an app.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The `~/Library/Containers/<bid>` URL (may not exist yet).
    static func liveURL(bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent(bundleID)
    }

    private static func defaultsKey(bundleID: String) -> String {
        "ContainerProfile.\(bundleID)"
    }

    /// The profile that launches use. "Default" when nothing was ever chosen.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The active profile name.
    static func activeName(bundleID: String) -> String {
        let name = UserDefaults.standard.string(forKey: defaultsKey(bundleID: bundleID))
        return (name?.isEmpty == false) ? name! : "Default"
    }

    /// All profile names for an app, sorted for display.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The profile names (empty when none exist).
    static func profiles(bundleID: String) -> [String] {
        let root = storeRoot(bundleID: bundleID)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return name
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Workspace liveness for profile guards (not the MCP verdict — that is
    /// `InspectControl.isAppRunning`, which also consults heartbeat/log evidence).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: True when the workspace lists the app as running.
    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Snapshot the live container (or an empty dir when never launched) as a new profile.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter name: The new profile name (no separators/traversal).
    /// - Throws: `OphanimError.invalidFolderName` on bad names; copy failures propagate.
    static func create(bundleID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"),
              !trimmed.contains("\\"), !trimmed.contains(":"), !trimmed.contains("..") else {
            throw OphanimError.invalidFolderName
        }
        let root = storeRoot(bundleID: bundleID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw OphanimError.invalidFolderName
        }
        let live = liveURL(bundleID: bundleID)
        if FileManager.default.fileExists(atPath: live.path) {
            try FileManager.default.copyItem(at: live, to: dest)
        } else {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        }
    }

    /// Make `name` the live container. Refuses while running and refuses unknown names, so a
    /// failed switch leaves the previous live tree exactly where it was.
    ///
    /// Move-then-move ordering: the live tree parks under the outgoing profile
    /// before the incoming tree moves in, so a mid-swap failure still has both
    /// trees on disk, just parked.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter name: The profile to activate.
    /// - Throws: `OphanimError.containerRunning` while the app runs;
    ///   `OphanimError.invalidFolderName` for unknown names.
    static func switchTo(bundleID: String, name: String) throws {
        guard !isRunning(bundleID: bundleID) else {
            throw OphanimError.containerRunning
        }
        let root = storeRoot(bundleID: bundleID)
        let incoming = root.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: incoming.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw OphanimError.invalidFolderName
        }
        let live = liveURL(bundleID: bundleID)
        let active = activeName(bundleID: bundleID)
        if name == active, FileManager.default.fileExists(atPath: live.path) {
            return
        }
        // Park the live tree under the outgoing profile first: a failure after this point still
        // has both trees on disk. Same volume, so both moves are renames.
        let parked = root.appendingPathComponent(active)
        if FileManager.default.fileExists(atPath: live.path) {
            if FileManager.default.fileExists(atPath: parked.path) {
                try FileManager.default.removeItem(at: parked)
            }
            try FileManager.default.moveItem(at: live, to: parked)
        }
        try FileManager.default.moveItem(at: incoming, to: live)
        UserDefaults.standard.set(name, forKey: defaultsKey(bundleID: bundleID))
    }

    /// Delete a stored profile. The active one is refused: it is the parked twin of the live
    /// tree, and deleting it would strand live data without its backup.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter name: The profile to delete.
    /// - Throws: `OphanimError.containerActive` for the active profile
    ///   (missing profiles: filesystem errors propagate).
    static func remove(bundleID: String, name: String) throws {
        guard name != activeName(bundleID: bundleID) else {
            throw OphanimError.containerActive
        }
        let target = storeRoot(bundleID: bundleID).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Launch hook: if the live container is missing but the active profile is stored (cleared
    /// data, first run after a profile was chosen elsewhere), move it into place. Anything else
    /// - live exists, nothing stored, any error - is left alone and logged: launch then
    /// proceeds with whatever exists, which is the original behavior.
    ///
    /// Never throws: any failure logs and launch proceeds.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    static func ensureActiveInPlace(bundleID: String) {
        do {
            let live = liveURL(bundleID: bundleID)
            guard !FileManager.default.fileExists(atPath: live.path) else { return }
            let incoming = storeRoot(bundleID: bundleID)
                .appendingPathComponent(activeName(bundleID: bundleID))
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: incoming.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            try FileManager.default.moveItem(at: incoming, to: live)
        } catch {
            Log.shared.error(error)
        }
    }
}
