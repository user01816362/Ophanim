//
//  ContainerService.swift
//  Ophanim
//
//  Container/log filesystem reads: sizes, reports, log-dir exposure.
//

import Foundation

/// Container/log filesystem reads: sizes, reports, log-dir exposure.
enum ContainerService {
    /// Recursive byte size of a directory (regular files only).
    ///
    /// - Parameter url: The directory to measure.
    /// - Returns: The total bytes, or nil when the directory cannot be enumerated.
    static func directorySize(_ url: URL) -> Int64? {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in en {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Resolved container report for an app: real path (not composed), size,
    /// prefs plist, and profiles. Agents get the paths without rebuilding them.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The report (`resolved` false with a `note` when no data
    ///   container matches — e.g. never launched).
    static func containerReport(_ bundleID: String) -> [String: Any] {
        var report: [String: Any] = ["bundleID": bundleID, "installed": AppQueryService.appURL(bundleID) != nil]

        let composed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent(bundleID)
        report["composedPath"] = composed.path
        report["composedPathExists"] = FileManager.default.fileExists(atPath: composed.path)

        guard let real = Uninstaller.containerURL(for: bundleID) else {
            report["resolved"] = false
            report["note"] = "The app is installed but no data container could be matched. It may "
                + "not have been launched yet, in which case macOS has not created one."
            return report
        }
        report["resolved"] = true
        report["containerPath"] = real.path
        report["containerExists"] = FileManager.default.fileExists(atPath: real.path)
        if let size = Self.directorySize(real) { report["bytes"] = size }
        // Same prefs plist the Container pane shows (AppContainer.userPrefsUrl)
        // and the library menu deletes — agents shouldn't have to rebuild the path.
        let prefs = AppContainer(bundleId: bundleID).userPrefsUrl
        report["preferencesPath"] = prefs.path
        report["preferencesExists"] = FileManager.default.fileExists(atPath: prefs.path)
        report["profiles"] = ContainerProfiles.profiles(bundleID: bundleID)
        report["activeProfile"] = ContainerProfiles.activeName(bundleID: bundleID)
        return report
    }
}
