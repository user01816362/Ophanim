//
//  HostedApp+Tools.swift
//  Ophanim
//
//  HostedApp tool surface: Galgal/DYLD checks + mutations shared by GUI and MCP.
//

import Foundation
// MARK: - Tools
extension HostedApp {
    /// Whether the Galgal runtime load command is present in the executable.
    ///
    /// Fail-open: a read error counts as present (logs), so an unreadable
    /// binary never triggers a redundant reinstall.
    ///
    /// - Returns: True when Galgal is injected or the check failed.
    func hasGalgal() -> Bool {
        do {
            return try Galgal.installedInExec(atURL: url.appendingEscapedPathComponent(info.executableName))
        } catch {
            Log.shared.error(error)
            return true
        }
    }

    func changeDyldLibraryPath(set: Bool? = nil, path: String) async -> Bool {
        info.lsEnvironment["DYLD_LIBRARY_PATH"] = info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""

        if let set = set {
            if set {
                info.lsEnvironment["DYLD_LIBRARY_PATH"]? += "\(path):"
            } else {
                info.lsEnvironment["DYLD_LIBRARY_PATH"] = info.lsEnvironment["DYLD_LIBRARY_PATH"]?
                    .replacingOccurrences(of: "\(path):", with: "")
            }

            do {
                try Shell.signApp(executable)
            } catch {
                Log.shared.error(error)
            }
        }

        guard let result = info.lsEnvironment["DYLD_LIBRARY_PATH"] else {
            return false
        }
        return result.contains(path)
    }
}
