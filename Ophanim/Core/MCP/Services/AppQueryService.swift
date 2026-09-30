import Foundation

/// File-backed app queries: filesystem + nm/strings effects. GUI-independent
/// so it works in headless `--mcp` stdio and in the running app's HTTP transport.
enum AppQueryService {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var container: URL {
        home.appendingPathComponent("Library/Containers/be.ophanim.Ophanim")
    }
    static var appsDir: URL { container.appendingPathComponent("Applications") }
    static var settingsDir: URL { container.appendingPathComponent("App Settings") }

    static func settingsURL(_ bundleID: String) -> URL {
        settingsDir.appendingPathComponent(bundleID).appendingPathExtension("plist")
    }

    struct AppEntry { let bundleID: String; let name: String; let version: String }

    /// The app's dynamically-imported TLS/crypto/sensitive symbols - the surface that DYLD_INTERPOSE
    /// can rebind (key for statically-linked apps: even a self-contained binary imports the OS's
    /// crypto/TLS primitives, and those calls ARE interposable). Grouped by what Ophanim can hook.
    static func importSurface(_ bundleID: String) -> [String: [String]] {
        guard let app = appURL(bundleID) else { return [:] }
        let info = PlistReader.appInfoDict(at: app.appendingPathComponent("Info.plist"))
        let exeName = (info["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let exe = app.appendingPathComponent(exeName)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        p.arguments = ["-u", exe.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let syms = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        func match(_ needles: [String]) -> [String] {
            syms.filter { s in needles.contains { s.contains($0) } }.sorted()
        }
        return [
            "tls": match(["SSLRead", "SSLWrite", "SSLHandshake", "SSLCreateContext", "SSLCopyPeerTrust",
                          "SSLSetSessionOption", "SSL_read", "SSL_write", "sec_protocol"]),
            "trust_pinning": match(["SecTrustEvaluate", "SecTrustCreate", "SecPolicyCreateSSL",
                                    "SecKeyRawVerify", "SecKeyVerifySignature"]),
            "crypto": match(["CCCrypt", "CCHmac", "CC_SHA", "SecKeyCreate", "SecKeyDecrypt", "SecKeyEncrypt"]),
            "keychain": match(["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete"]),
            "process": match(["_dlopen", "posix_spawn", "_execve", "ptrace", "_fork"])
        ]
    }

    /// Path to the app's main executable, if installed.
    static func appExecutable(_ bundleID: String) -> URL? {
        guard let app = appURL(bundleID) else { return nil }
        let info = PlistReader.appInfoDict(at: app.appendingPathComponent("Info.plist"))
        let name = (info["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        return app.appendingPathComponent(name)
    }

    /// Search the app binary for symbols / ObjC class & selector names matching a keyword - recon for
    /// finding hook targets (e.g. an SDK's response classes/selectors). Returns demangled symbols +
    /// ObjC-name strings, capped. Callers must allowlist `keyword` (see ReconTools.findSymbols):
    /// it reaches shell pipelines below.
    static func findSymbols(_ bundleID: String, _ keyword: String) -> [String: [String]] {
        guard let exe = appExecutable(bundleID), !keyword.isEmpty else { return [:] }
        let safe = keyword.replacingOccurrences(of: "'", with: "")
        func sh(_ cmd: String) -> [String] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return [] }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (String(data: d, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }
        let q = "'\(safe)'"
        // Demangled symbols (incl. Swift types/methods) + ObjC class/selector strings.
        let syms = sh("nm '\(exe.path)' 2>/dev/null | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -80")
        let classes = sh("strings -a '\(exe.path)' 2>/dev/null | grep -E '^_TtC' | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -60")
        let selectors = sh("strings -a '\(exe.path)' 2>/dev/null | grep -iE '^[a-zA-Z][a-zA-Z0-9_]*:?$' | grep -i \(q) | sort -u | head -80")
        return ["symbols": syms, "swiftClasses": classes, "selectors": selectors]
    }

    /// Filesystem URL of an installed hosted app bundle, if present.
    static func appURL(_ bundleID: String) -> URL? {
        let url = appsDir.appendingPathComponent(bundleID).appendingPathExtension("app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Uninstall a hosted app: remove its bundle and per-app config (settings, keymap, entitlements,
    /// ChainGuard) - the same set the GUI's uninstall clears. When `purgeData` is true, also delete
    /// the app's OS data container (its captured event logs live there). Returns the paths removed.
    @discardableResult
    static func uninstall(_ bundleID: String, purgeData: Bool) -> [String] {
        let fm = FileManager.default
        var targets: [URL] = [
            appsDir.appendingPathComponent(bundleID).appendingPathExtension("app"),
            settingsURL(bundleID),
            container.appendingPathComponent("Keymapping").appendingPathComponent(bundleID),
            container.appendingPathComponent("Entitlements").appendingPathComponent(bundleID).appendingPathExtension("plist"),
            container.appendingPathComponent("ChainGuard").appendingPathComponent(bundleID)
        ]
        if purgeData {
            targets.append(home.appendingPathComponent("Library/Containers/\(bundleID)"))
        }
        var removed: [String] = []
        for target in targets where fm.fileExists(atPath: target.path) {
            if (try? fm.removeItem(at: target)) != nil { removed.append(target.path) }
        }
        return removed
    }

    static func listApps() -> [AppEntry] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: appsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [AppEntry] = []
        for app in dirs where app.pathExtension == "app" {
            let info = app.appendingPathComponent("Info.plist")
            let plist = PlistReader.appInfoDict(at: info)
            let bid = (plist["CFBundleIdentifier"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            let name = (plist["CFBundleName"] as? String)
                ?? (plist["CFBundleDisplayName"] as? String) ?? bid
            let version = (plist["CFBundleShortVersionString"] as? String) ?? "?"
            out.append(AppEntry(bundleID: bid, name: name, version: version))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
