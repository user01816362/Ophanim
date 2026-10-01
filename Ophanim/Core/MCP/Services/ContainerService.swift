import Foundation

/// Container/log filesystem reads: sizes, reports, log-dir exposure.
enum ContainerService {
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
        report["profiles"] = ContainerProfiles.profiles(bundleID: bundleID)
        report["activeProfile"] = ContainerProfiles.activeName(bundleID: bundleID)
        return report
    }
}
