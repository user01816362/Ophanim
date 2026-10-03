//
//  ContainerService.swift
//  Ophanim
//
//  Container/log filesystem reads: sizes, reports, log-dir exposure.
//

import Foundation

/// Container/log filesystem reads: sizes, reports, log-dir exposure.
enum ContainerService {
    /// Roots a host-side read may come from for an app: its composed + resolved
    /// data containers and its log dirs. Every file-content tool (sqlite browser,
    /// file reader, keychain projection) confines to these — the reader CLIs must
    /// never be pointed at arbitrary host paths.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: Existing directories among the allowed roots.
    static func readableRoots(_ bundleID: String) -> [URL] {
        var roots = [AppContainer(bundleId: bundleID).containerUrl]
        if let real = Uninstaller.containerURL(for: bundleID) { roots.append(real) }
        roots.append(contentsOf: ReportBuilder.logDirs(bundleID))
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.standardizedFileURL }
    }

    /// True when `url` resolves inside the app's readable roots.
    ///
    /// - Parameters:
    ///   - url: Candidate file URL.
    ///   - bundleID: The app's bundle identifier.
    /// - Returns: Whether the standardized path sits under an allowed root.
    static func isReadable(_ url: URL, bundleID: String) -> Bool {
        let p = url.standardizedFileURL.path
        return readableRoots(bundleID).contains { p.hasPrefix($0.path) }
    }

    /// JSON-safe projection of arbitrary plist-decoded values (Data → base64,
    /// dates → ISO8601, nested containers recursed, anything else stringified).
    ///
    /// - Parameter value: A plist-decoded value.
    /// - Returns: JSONSerialization-safe equivalent.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n
        case let d as Data: return ["$base64": d.base64EncodedString()]
        case let dt as Date:
            return ISO8601DateFormatter().string(from: dt)
        case let a as [Any]: return a.map(jsonSafe)
        case let m as [String: Any]: return m.mapValues(jsonSafe)
        default: return String(describing: value)
        }
    }

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
        // Signing truth, computed live (not the install-time claim): composed
        // entitlements plus a codesign parse + top-seal check. A broken seal here
        // is the "installs but dies on launch" signature (proven on Aloha's
        // Settings.bundle case) — check this before deeper debugging.
        if let url = AppQueryService.appURL(bundleID) {
            let app = HostedApp(appUrl: url)
            if let ents = try? Entitlements.composeEntitlements(app) {
                report["entitlements"] = ContainerService.jsonSafe(ents)
            }
            if let dv = try? Shell.run(print: false, "/usr/bin/codesign", "-dv", url.path) {
                var sig: [String: Any] = [:]
                for line in dv.split(separator: "\n") {
                    let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    if ["Identifier", "Signature", "TeamIdentifier"].contains(kv[0]) {
                        sig[kv[0]] = kv[1]
                    }
                }
                if !sig.isEmpty { report["codeSignature"] = sig }
            }
            report["sealValid"] = (try? Shell.run(print: false, "/usr/bin/codesign",
                                                  "--verify", url.path)) != nil
        }
        return report
    }
}
