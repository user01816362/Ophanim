//
//  Shell.swift
//  Ophanim
//
//  Privileged/process runner: shell-outs, codesign, LLDB, Metal HUD.
//  Failures throw the command's output as the error.
//

import Foundation

@Observable class Shell {
    /// Lock-guarded box for values mutated from concurrently-executing
    /// callbacks (Swift 6: no mutating captured vars).
    private final class LockBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs a binary with separate argv (never a shell string: no injection
    /// surface). Non-zero exit throws the command's combined output.
    ///
    /// - Parameter print: Whether to also mirror output to the Log.
    /// - Parameter binary: The executable path.
    /// - Parameter args: The argv entries.
    /// - Returns: The combined stdout+stderr text.
    /// - Throws: The command's output text on non-zero exit.
    @discardableResult
    static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        if print {
            Log.shared.log(String(data: output, encoding: .utf8) ?? "Shell error occured")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw String(data: output, encoding: .utf8) ?? "Shell error occured"
        }
        return String(data: output, encoding: .utf8) ?? "Shell error occured"
    }

    static func runSu(_ args: [String], _ argc: String) -> Bool {
        let password = argc
        let passwordWithNewline = password + "\n"
        let sudo = Process()
        sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudo.arguments = args
        let sudoIn = Pipe()
        let sudoOut = Pipe()
        sudo.standardOutput = sudoOut
        sudo.standardError = sudoOut
        sudo.standardInput = sudoIn
        do {
            try sudo.run()
        } catch {
            Log.shared.log("sudo failed to launch: \(error.localizedDescription)", isError: true)
            return false
        }

        let result = LockBox(true)

        // Show the output as it is produced
        sudoOut.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.count == 0 { return }

            if let out = String(bytes: data, encoding: .utf8) {
                Log.shared.log(out)
                if out.contains("password") {
                    result.set(false)
                }
            }
        }
        if let data = passwordWithNewline.data(using: .utf8) {
            // Write the password
            sudoIn.fileHandleForWriting.write(data)

            // Close the file handle after writing the password; avoids a
            // hang for incorrect password.
            try? sudoIn.fileHandleForWriting.close()
        }

        // Make sure we don't disappear while output is still being produced.
        sudo.waitUntilExit()
        return result.get()
    }

    static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }

    static func signAppWith(_ exec: URL, entitlements: URL) throws {
        let dir = exec.deletingLastPathComponent()
        try signNestedCode(in: dir)
        try run("/usr/bin/codesign", "-fs-", dir.path,
                "--entitlements", entitlements.path)
    }

    static func signApp(_ exec: URL) throws {
        let dir = exec.deletingLastPathComponent()
        try signNestedCode(in: dir)
        try run("/usr/bin/codesign", "-fs-", dir.path,
                "--preserve-metadata=entitlements")
    }

    /// Sign nested code leaf-first (TN2206 discourages `--deep` for signing).
    /// Signs bundled frameworks/bundles/dylibs plus PlugIns/Frameworks/Helpers
    /// contents before the caller signs the top-level bundle.
    /// Resource-only bundles without Info.plist (e.g. Settings.bundle) are not
    /// signable code — codesign rejects them with "bundle format unrecognized",
    /// which used to abort the whole seal and ship a dead app. They are skipped
    /// (the top-level seal covers their resources); same for non-Mach-O files.
    private static func signNestedCode(in dir: URL) throws {
        let fm = FileManager.default
        let nestedExts = ["framework", "bundle", "dylib", "app", "appex"]
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where nestedExts.contains(item.pathExtension) {
                guard isSignableCode(item) else {
                    Log.shared.log("Skipping resource-only \(item.lastPathComponent) (no code to sign)")
                    continue
                }
                try run("/usr/bin/codesign", "-fs-", item.path)
            }
        }
        for sub in ["PlugIns", "Frameworks", "Helpers"] {
            let subdir = dir.appendingPathComponent(sub)
            guard let nested = try? fm.contentsOfDirectory(
                at: subdir, includingPropertiesForKeys: nil) else { continue }
            for item in nested {
                guard isSignableCode(item) else {
                    Log.shared.log("Skipping resource-only \(item.lastPathComponent) (no code to sign)")
                    continue
                }
                try run("/usr/bin/codesign", "-fs-", item.path)
            }
        }
    }

    /// A nested item is signable code when it is a Mach-O file or a bundle directory
    /// carrying Info.plist — top-level or modern Contents/ layout (codesign identifies
    /// bundles through it: resource bundles *with* Info.plist sign fine, ones without
    /// abort the seal). Same Mach-O magic the installer itself uses to resolve binaries.
    private static func isSignableCode(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Info.plist").path)
                || FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("Contents/Info.plist").path)
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        return Array(data) == [202, 254, 186, 190] || Array(data) == [207, 250, 237, 254]
    }

    static func setMetalHUD(_ bundleID: String, enabled: Bool) throws {
        try run("/usr/bin/defaults", "write", bundleID,
                      "MetalForceHudEnabled", "-bool", String(enabled))
    }

    static func lldb(_ url: URL, withTerminalWindow: Bool = false) throws {
        Task(priority: .utility) {
            if withTerminalWindow {
                let command = "/usr/bin/lldb -o run \(url.esc) -o exit"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                let osascript = """
                    tell app "Terminal"
                        reopen
                        activate
                        do script "\(command)"
                    end tell
                """
                let appleScript = NSAppleScript(source: osascript)
                var possibleError: NSDictionary?
                appleScript?.executeAndReturnError(&possibleError)

                if let error = possibleError {
                    for key in error.allKeys {
                        if let key = key as? String {
                            throw error.value(forKey: key).debugDescription
                        }
                    }
                }
            } else {
                try run("/usr/bin/lldb", "-o", "run", url.path, "-o", "exit")
            }
        }
    }
}

extension Swift.String: Swift.Error { }

extension Swift.String: Foundation.LocalizedError {
    public var errorDescription: String? { self }
}
