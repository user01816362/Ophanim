//
//  IPA.swift
//  Ophanim
//
//  IPA archive handle: temp-dir lifecycle, unzip to BaseApp, quarantine removal,
//  repack. Thin wrapper over unzip/zip shell-outs; the Installer owns the pipeline.
//

import Foundation

/// An IPA file plus its scratch dir. Allocate before unzip, release after the final
/// URL is moved out (both success and failure paths must release).
public class IPA: @unchecked Sendable {
    public let url: URL
    public private(set) var tmpDir: URL?

    public init(url: URL) {
        self.url = url
    }

    /// Creates the scratch dir used for unzipping.
    ///
    /// - Throws: FileManager errors when the dir cannot be created.
    public func allocateTempDir() throws {
        tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: URL(fileURLWithPath: "/Users"),
                                             create: true)
    }

    /// Deletes the scratch dir and clears it (safe to call when never allocated).
    public func releaseTempDir() {
        guard let workDir = tmpDir else {
            return
        }

        FileManager.default.delete(at: workDir)

        tmpDir = nil
    }

    /// Strips the quarantine xattr so the installed app launches without Gatekeeper
    /// friction.
    ///
    /// - Parameter execUrl: The installed app URL.
    /// - Throws: Shell errors from xattr.
    public func removeQuarantine(_ execUrl: URL) throws {
        try Shell.run("/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", execUrl.relativePath)
    }

    /// Unzips the IPA into the scratch dir and locates the .app.
    ///
    /// - Returns: The unzipped app handle.
    /// - Throws: `OphanimError.appCorrupted` when unzip fails or no scratch dir exists.
    public func unzip() throws -> BaseApp {
        if let workDir = tmpDir {
            if try Shell.run("/usr/bin/unzip",
                             "-oq", url.path, "-d", workDir.path) == "" {
                return try Installer.fromIPA(detectingAppNameInFolder: workDir.appendingPathComponent("Payload"))
            } else {
                throw OphanimError.appCorrupted
            }
        } else {
            throw OphanimError.appCorrupted
        }
    }

    /// Re-zips the app dir into a new IPA in Documents (export path only).
    ///
    /// - Parameter app: The converted app URL.
    /// - Returns: The repacked IPA URL.
    /// - Throws: Shell/file errors from zip.
    func packIPABack(app: URL) throws -> URL {
        let payload = app.deletingPathExtension().deletingLastPathComponent()
        let name = app.deletingPathExtension().lastPathComponent

        let newIpa = getDocumentsDirectory()
            .appendingEscapedPathComponent(name)
            .appendingPathExtension("ipa")

        try Shell.run("/usr/bin/zip", "-r", newIpa.path, payload.path)

        return newIpa
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

}
