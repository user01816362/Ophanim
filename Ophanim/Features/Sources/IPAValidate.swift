//
//  IPAValidate.swift
//  Ophanim
//
//  Fail-fast validation for IPA downloads and installed apps. Both of the recurring
//  mysteries came from validating too late: an HTML error page saved as ".ipa" only
//  surfaced as unzip corruption, and a non-Catalyst binary only surfaced as "error
//  during conversion" at launch. Validate at the boundary, state the actual finding.
//

import Foundation

enum IPAValidate {
    /// A downloaded file must be a zip (PK\x03\x04) before anything treats it as an IPA.
    /// Repo links routinely serve HTML interstitials or quota pages instead of bytes.
    static func downloadedFile(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw OphanimError.corruptedFile(url.lastPathComponent, "unreadable download")
        }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4) ?? Data()
        guard magic?.count == 4, magic![0] == 0x50, magic![1] == 0x4B,
              magic![2] == 0x03, magic![3] == 0x04 else {
            throw OphanimError.corruptedFile(url.lastPathComponent,
                                             "not a zip archive (HTML error page?)")
        }
    }

    /// An installed .app must have a loadable Catalyst executable. Returns the bundle
    /// id from its own Info.plist. Throws the honest reason otherwise.
    static func installedApp(at appURL: URL) throws -> String {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let info = (try? Data(contentsOf: infoURL))
            .flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
              let bid = (info["CFBundleIdentifier"] as? String), !bid.isEmpty else {
            throw OphanimError.corruptedFile(appURL.lastPathComponent, "Info.plist unreadable")
        }
        guard let exeName = info["CFBundleExecutable"] as? String, !exeName.isEmpty else {
            throw OphanimError.corruptedFile(bid, "CFBundleExecutable missing")
        }
        let exe = appURL.appendingPathComponent(exeName)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw OphanimError.corruptedFile(bid, "main executable missing (\(exeName))")
        }
        if (try? Macho.isMachoEncrypted(atURL: exe)) == true {
            throw OphanimError.appEncrypted
        }
        // Any-match (same rule as launch): converted binaries carry the iOS command
        // first and Catalyst second - first-match would refuse working apps.
        guard (try? Macho.hasCatalystPlatform(exe)) == true else {
            throw OphanimError.unsupportedPlatform(bid, "no Mac Catalyst slice")
        }
        return bid
    }
}
