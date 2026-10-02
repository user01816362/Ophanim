//
//  AppQueryService.swift
//  Ophanim
//
//  File-backed app queries: filesystem + nm/strings effects. GUI-independent
//  so it works in headless `--mcp` stdio and in the running app's HTTP transport.
//

import Foundation

/// File-backed app queries: filesystem + nm/strings effects. GUI-independent
/// so it works in headless `--mcp` stdio and in the running app's HTTP transport.
enum AppQueryService {
    /// The current user's home directory (container paths root here).
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Ophanim's own data container.
    static var container: URL {
        home.appendingPathComponent("Library/Containers/be.ophanim.Ophanim")
    }
    /// Where installed hosted-app bundles live.
    static var appsDir: URL { container.appendingPathComponent("Applications") }
    /// Where per-app settings plists live.
    static var settingsDir: URL { container.appendingPathComponent("App Settings") }

    /// Settings-plist URL for an app.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The plist URL (may not exist yet).
    static func settingsURL(_ bundleID: String) -> URL {
        settingsDir.appendingPathComponent(bundleID).appendingPathExtension("plist")
    }

    /// One installed hosted app (inventory row for `list_apps`).
    struct AppEntry { let bundleID: String; let name: String; let version: String }

    /// The app's dynamically-imported TLS/crypto/sensitive symbols - the surface that DYLD_INTERPOSE
    /// can rebind (key for statically-linked apps: even a self-contained binary imports the OS's
    /// crypto/TLS primitives, and those calls ARE interposable). Grouped by what Ophanim can hook.
    ///
    /// Runs `nm -u` on the main executable; an unreadable binary yields an empty
    /// surface rather than an error.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: Symbols grouped by `tls`/`trust_pinning`/`crypto`/`keychain`/`process`.
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
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The executable URL, or nil when the app is not installed.
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
    ///
    /// The keyword is single-quote-stripped before interpolation (defense in depth;
    /// the allowlist at the call site is the real guard).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter keyword: Caller-allowlisted substring.
    /// - Returns: `symbols` + `swiftClasses` + `selectors` (each capped); empty
    ///   when the app is not installed or the keyword is empty.
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
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The `.app` URL, or nil when not installed.
    static func appURL(_ bundleID: String) -> URL? {
        let url = appsDir.appendingPathComponent(bundleID).appendingPathExtension("app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Target inventory shared by preview and execution, so they agree.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter purgeData: Whether to include the OS data container targets.
    /// - Returns: The removal targets plus whether the container failed to resolve.
    static func uninstallTargets(_ bundleID: String, purgeData: Bool) -> (targets: [URL], unresolved: Bool) {
        var targets = Uninstaller.perAppState(forBundleID: bundleID)
        var unresolvedContainer = false
        if purgeData {
            let external = Uninstaller.externalState(forBundleID: bundleID)
            targets += external.paths
            unresolvedContainer = external.unresolved
        }
        return (targets, unresolvedContainer)
    }

    /// Dry-run twin of `uninstall`: what would be removed, nothing deleted.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter purgeData: Whether the data container is included.
    /// - Returns: Report with `wouldRemove`, `count`, `purgeData`, and (when
    ///   purging) `containerResolved` + a `note` when unresolved.
    static func uninstallPreview(_ bundleID: String, purgeData: Bool) -> [String: Any] {
        let (targets, unresolvedContainer) = uninstallTargets(bundleID, purgeData: purgeData)
        let existing = targets
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
        var report: [String: Any] = [
            "dryRun": true,
            "bundleID": bundleID,
            "wouldRemove": existing,
            "count": existing.count,
            "purgeData": purgeData
        ]
        if purgeData {
            report["containerResolved"] = !unresolvedContainer
            if unresolvedContainer {
                report["note"] = "No data container was found. The app may not have been launched yet, "
                    + "in which case macOS has not created one."
            }
        }
        return report
    }

    /// Uninstall a hosted app: remove its bundle and per-app config (settings, keymap, entitlements,
    /// tweak store, ChainGuard) - the Uninstaller-resolved set. When `purgeData` is true, also
    /// delete the app's OS data container (resolved, not composed). Returns removed/missing paths
    /// plus whether the container resolved, so callers can tell "nothing to remove" apart.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter purgeData: Whether to also delete the OS data container.
    /// - Returns: Report with `removed`, `missing`, `count`, `purgeData`, and (when
    ///   purging) `containerResolved`.
    @discardableResult
    static func uninstall(_ bundleID: String, purgeData: Bool) -> [String: Any] {
        let fm = FileManager.default
        let (targets, unresolvedContainer) = uninstallTargets(bundleID, purgeData: purgeData)
        var removed: [String] = []
        for target in targets where fm.fileExists(atPath: target.path) {
            if (try? fm.removeItem(at: target)) != nil { removed.append(target.path) }
        }
        var missing: [String] = []
        for target in targets where !removed.contains(target.path) { missing.append(target.path) }
        var report: [String: Any] = [
            "bundleID": bundleID,
            "removed": removed,
            "missing": missing,
            "count": removed.count,
            "purgeData": purgeData
        ]
        if purgeData {
            report["containerResolved"] = !unresolvedContainer
            if unresolvedContainer {
                report["note"] = "No data container was found. The app may not have been launched yet, "
                    + "in which case macOS has not created one."
            }
        }
        return report
    }

    /// All installed hosted apps, sorted by display name.
    ///
    /// - Returns: The `AppEntry` rows (bundleID, name, version; fallbacks when
    ///   the Info.plist is missing keys); empty when the directory is absent.
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
