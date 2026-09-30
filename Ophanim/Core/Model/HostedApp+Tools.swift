//
//  HostedApp+Tools.swift
//  Ophanim
//

import Foundation
// MARK: - Tools
extension HostedApp {
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
