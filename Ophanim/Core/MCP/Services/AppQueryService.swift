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
        // Class grep covers both manglings: legacy _TtC AND Swift ≥5.1 _$s (the
        // classifier in ReportBuilder already knows both; the grep did not).
        let syms = sh("nm '\(exe.path)' 2>/dev/null | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -80")
        let classes = sh("strings -a '\(exe.path)' 2>/dev/null | grep -E '^(_TtC|_[$]s)' | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -60")
        let selectors = sh("strings -a '\(exe.path)' 2>/dev/null | grep -iE '^[a-zA-Z][a-zA-Z0-9_]*:?$' | grep -i \(q) | sort -u | head -80")
        return ["symbols": syms, "swiftClasses": classes, "selectors": selectors]
    }

    /// Paged full symbol dump (no keyword guessing): same `nm | swift-demangle`
    /// pipeline as findSymbols, `sort -u`, sliced host-side. Bounded output.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter kind: `symbols` (default), `classes`, or `selectors`.
    /// - Parameter page: Zero-based page.
    /// - Parameter perPage: Rows per page (default 200, max 500).
    /// - Returns: `total` + the page rows, or [:] when unavailable.
    static func allSymbols(_ bundleID: String, kind: String = "symbols",
                           page: Int = 0, perPage: Int = 200) -> [String: Any] {
        guard let exe = appExecutable(bundleID) else { return [:] }
        let per = min(max(perPage, 1), 500)
        func sh(_ cmd: String) -> [String] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return [] }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (String(data: d, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }
        let rows: [String]
        switch kind {
        case "classes":
            rows = sh("strings -a '\(exe.path)' 2>/dev/null | grep -E '^(_TtC|_[$]s)' | xcrun swift-demangle 2>/dev/null | sort -u | head -2000")
        case "selectors":
            rows = sh("strings -a '\(exe.path)' 2>/dev/null | grep -iE '^[a-zA-Z][a-zA-Z0-9_]*:?$' | sort -u | head -2000")
        default:
            rows = sh("nm '\(exe.path)' 2>/dev/null | xcrun swift-demangle 2>/dev/null | sort -u | head -2000")
        }
        let start = max(page, 0) * per
        guard start < rows.count else { return ["total": rows.count, "page": page, "rows": []] as [String: Any] }
        return ["total": rows.count, "page": page,
                "rows": Array(rows[start..<min(start + per, rows.count)])] as [String: Any]
    }

    /// Bundle Info.plist projection + semantic checks for launch planning:
    /// deep-link schemes (→ launch_app openURL), query schemes, ATS
    /// exceptions (cleartext watchlist), background modes, usage-description
    /// keys (missing key + observed API use = crash signature), version skew.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: `plist` (JSON-safe dict) + `checks` (finding strings).
    static func appPlistReport(_ bundleID: String) -> [String: Any] {
        guard let app = appURL(bundleID) else { return [:] }
        let info = PlistReader.appInfoDict(at: app.appendingPathComponent("Info.plist"))
        var checks: [String] = []
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap {
            ($0["CFBundleURLSchemes"] as? [String]) ?? []
        }
        if !schemes.isEmpty { checks.append("url-schemes: \(schemes.joined(separator: ", ")) (launch_app openURL targets)") }
        if let q = info["LSApplicationQueriesSchemes"] as? [String], !q.isEmpty {
            checks.append("queries-schemes: \(q.joined(separator: ", ")) (canOpenURL surface)")
        }
        if let ats = info["NSAppTransportSecurity"] as? [String: Any] {
            if (ats["NSAllowsArbitraryLoads"] as? Bool) == true {
                checks.append("ats: arbitrary loads ALLOWED (watchlist cleartext hosts in tail_events)")
            }
            if let ex = ats["NSExceptionDomains"] as? [String: Any], !ex.isEmpty {
                checks.append("ats-exceptions: \(ex.keys.sorted().joined(separator: ", "))")
            }
        }
        if let modes = info["UIBackgroundModes"] as? [String], !modes.isEmpty {
            checks.append("background-modes: \(modes.joined(separator: ", ")) (expect background network; use long polls)")
        }
        let usageKeys = info.keys.filter { $0.hasSuffix("UsageDescription") }
        if !usageKeys.isEmpty { checks.append("usage-descriptions: \(usageKeys.sorted().joined(separator: ", "))") }
        let v = info["CFBundleShortVersionString"] as? String
        let b = info["CFBundleVersion"] as? String
        if v == nil || b == nil { checks.append("version-skew: missing CFBundleShortVersionString/CFBundleVersion") }
        if let fam = info["UIDeviceFamily"] as? [Int], !fam.contains(2) {
            checks.append("device-family: phone-only (\(fam)) — iPad-layout flows untestable")
        }
        return ["plist": ContainerService.jsonSafe(info), "checks": checks]
    }

    /// Approximate string cross-refs (table + pointer-scan tier, NOT
    /// instruction xrefs): `strings -t d` gives file offsets; an 8-byte
    /// little-endian scan of __DATA finds pointer slots holding those
    /// offsets, corrected by the __TEXT slide (file pointers are linked
    /// vmaddrs: fileOffset = value - (vmaddr - fileoff) from `otool -l`).
    /// Approximate (coincidental integer matches possible) but load-bearing
    /// for triage: string → candidate data landlords → inline-hook anchors.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter keyword: Caller-allowlisted substring of the string.
    /// - Returns: `refs` ([{string, stringOffset, refOffset}]) + `approximate: true`.
    static func stringXrefs(_ bundleID: String, _ keyword: String) -> [String: Any] {
        guard let exe = appExecutable(bundleID), !keyword.isEmpty else { return [:] }
        let safe = keyword.replacingOccurrences(of: "'", with: "").lowercased()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: exe.path)),
              data.count <= 256 * 1024 * 1024 else { return [:] }
        // Segment slides via the shared otool -l parse (file holds linked
        // vmaddrs, not offsets; standard PIE base fallback, still approximate).
        let slides = AppQueryService.segmentSlides(exe: exe)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        p.arguments = ["-a", "-t", "d", exe.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [:] }
        let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // (offset, string, end): only tracked strings participate.
        var ranges: [(start: UInt64, end: UInt64, text: String)] = []
        for line in txt.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " ") else { continue }
            guard let off = UInt64(t[..<sp]) else { continue }
            let s = String(t[t.index(after: sp)...])
            guard s.lowercased().contains(safe) else { continue }
            ranges.append((off, off + UInt64(s.utf8.count), s))
            if ranges.count >= 2000 { break }
        }
        guard !ranges.isEmpty else { return ["refs": [], "approximate": true] }
        let starts = ranges.map { $0.start }.sorted()
        var refs: [[String: Any]] = []
        let n = data.count / 8
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < n && refs.count < 200 {
                let v = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian
                for slide in slides {
                    guard v >= slide else { continue }
                    let f = v - slide
                    var lo = 0, hi = starts.count - 1, cand = -1
                    while lo <= hi {
                        let mid = (lo + hi) / 2
                        if starts[mid] <= f { cand = mid; lo = mid + 1 } else { hi = mid - 1 }
                    }
                    if cand >= 0 {
                        let st = starts[cand]
                        if let r = ranges.first(where: { $0.start == st }), f < r.end {
                            refs.append(["string": String(r.text.prefix(120)),
                                         "stringOffset": st, "refOffset": UInt64(i * 8)])
                            break
                        }
                    }
                }
                i += 1
            }
        }
        return ["refs": refs, "approximate": true]
    }

    /// Raw protocol/conformance section dumps (v0): `otool -s` over the ObjC
    /// protocol list and Swift conformance sections, bounded text. Class
    /// names surface as strings; typed parsing is a later v1.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: `sections` (name → capped dump lines).
    static func protocolSections(_ bundleID: String) -> [String: Any] {
        guard let exe = appExecutable(bundleID) else { return [:] }
        var sections: [String: [String]] = [:]
        for (seg, sect) in [("__DATA", "__objc_protolist"), ("__TEXT", "__swift5_protos"),
                            ("__TEXT", "__swift5_proto"), ("__DATA", "__objc_classlist")] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
            p.arguments = ["-s", seg, sect, exe.path]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let lines = txt.split(separator: "\n").map(String.init)
            if lines.count > 1 { sections["\(seg),\(sect)"] = Array(lines.prefix(150)) }
        }
        return ["sections": sections]
    }

    /// One parsed `otool -l` load-command block: command + the fields agents
    /// query (dylib name, segment geometry, uuid, cryptid). Single owner so
    /// weak-link, slide, uuid, and cryptid reads never drift into separate
    /// parsers (DRY: ReconTools + stringXrefs + identity all use this).
    struct OtoolLoadCommand {
        var cmd: String = ""
        var name: String = ""
        var segname: String = ""
        var vmaddr: UInt64?
        var fileoff: UInt64?
        var uuid: String = ""
        var cryptid: String = ""
    }

    /// Parses `otool -l` into load-command blocks (one shell-out, shared).
    ///
    /// - Parameter exe: The Mach-O file.
    /// - Returns: The blocks in file order ([] when otool fails).
    static func loadCommands(exe: URL) -> [OtoolLoadCommand] {
        guard let lud = try? Shell.run(print: false, "/usr/bin/otool", "-l", exe.path) else { return [] }
        func num(_ t: String) -> UInt64? {
            var s = t.split(separator: " ").last.map(String.init) ?? ""
            if s.hasPrefix("0x") { s = String(s.dropFirst(2)); return UInt64(s, radix: 16) }
            return UInt64(s)
        }
        var out: [OtoolLoadCommand] = []
        var cur = OtoolLoadCommand()
        var open = false
        for line in lud.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Load command ") {
                if open { out.append(cur) }
                cur = OtoolLoadCommand(); open = true
            }
            else if t.hasPrefix("cmd ") { cur.cmd = String(t.dropFirst(4)) }
            else if t.hasPrefix("name ") { cur.name = String(t.dropFirst(5).split(separator: " ").first ?? "") }
            else if t.hasPrefix("segname ") { cur.segname = String(t.dropFirst(8)) }
            else if t.hasPrefix("vmaddr ") { cur.vmaddr = num(t) }
            else if t.hasPrefix("fileoff ") { cur.fileoff = num(t) }
            else if t.hasPrefix("uuid ") { cur.uuid = String(t.dropFirst(5)) }
            else if t.hasPrefix("cryptid ") { cur.cryptid = String(t.dropFirst(8)) }
        }
        if open { out.append(cur) }
        return out
    }

    /// Segment slides (vmaddr − fileoff) for file-pointer → file-offset
    /// correction (file holds linked vmaddrs, not offsets).
    ///
    /// - Parameter exe: The Mach-O file.
    /// - Returns: The slides (standard PIE base fallback, still approximate).
    static func segmentSlides(exe: URL) -> [UInt64] {
        let slides = loadCommands(exe: exe).compactMap { c -> UInt64? in
            guard let vm = c.vmaddr, let fo = c.fileoff, vm >= fo else { return nil }
            return vm - fo
        }
        return slides.isEmpty ? [0x100000000] : slides
    }

    /// Whole-file SHA-256 via pinned `/usr/bin/openssl` (5× faster than
    /// shasum at 100 MB, host-verified), falling back to `/usr/bin/shasum`.
    /// Bare `openssl` is never used (Homebrew shadowing).
    ///
    /// - Parameter path: The file to hash.
    /// - Returns: Lowercase hex digest, or nil when neither tool runs.
    static func sha256File(_ path: String) -> String? {
        func digest(_ exe: String, _ args: [String]) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            // openssl: "SHA2-256(path)= <hash>"; shasum: "<hash>  path".
            let candidates = txt.split(separator: " ").map(String.init)
                + (txt.split(separator: "=").last.map { [$0.trimmingCharacters(in: .whitespacesAndNewlines)] } ?? [])
            for tok in candidates where tok.count == 64
                    && tok.range(of: "[^0-9a-fA-F]", options: .regularExpression) == nil {
                return tok.lowercased()
            }
            return nil
        }
        return digest("/usr/bin/openssl", ["dgst", "-sha256", path])
            ?? digest("/usr/bin/shasum", ["-a", "256", path])
    }

    /// Identity projection for an installed app: CDHash (Apple's identity
    /// primitive) + whole-file sha256 (change detection) + LC_UUID (build
    /// provenance) + signing authority + cryptid (FairPlay gate) + verify
    /// status. Read-only; every byte-export verb gates on this first.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The projection dict (empty when the app is not installed).
    static func appIdentity(_ bundleID: String) -> [String: Any] {
        guard let app = appURL(bundleID), let exe = appExecutable(bundleID) else { return [:] }
        func sh(_ exePath: String, _ args: [String]) -> (out: String, ok: Bool) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exePath); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return ("", false) }
            let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            return (txt, p.terminationStatus == 0)
        }
        // codesign writes display info to STDERR — merge by capturing both via shell redirect.
        let disp = sh("/bin/sh", ["-c", "codesign -d -vvv '\(app.path)' 2>&1"])
        func kv(_ key: String) -> String? {
            disp.out.split(separator: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(key + "=") else { return nil }
                return String(t.dropFirst(key.count + 1))
            }.first
        }
        let auths = disp.out.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Authority=") else { return nil }
            return String(t.dropFirst("Authority=".count))
        }
        let cmds = loadCommands(exe: exe)
        let uuids = cmds.filter { $0.cmd == "LC_UUID" }.map { $0.uuid }.filter { !$0.isEmpty }
        let cryptid = cmds.first { $0.cmd == "LC_ENCRYPTION_INFO_64" || $0.cmd == "LC_ENCRYPTION_INFO" }
            .flatMap { Int($0.cryptid) } ?? 0
        let verify = sh("/bin/sh", ["-c", "codesign --verify --deep --strict '\(app.path)' 2>&1"])
        let entPlist = sh("/bin/sh", ["-c", "codesign -d --entitlements :- '\(app.path)' 2>/dev/null"])
        var entitlements: Any = NSNull()
        if !entPlist.out.isEmpty,
           let data = entPlist.out.data(using: .utf8),
           let obj = PlistReader.plistDict(data: data) {
            entitlements = ContainerService.jsonSafe(obj)
        }
        return [
            "identifier": kv("Identifier") ?? NSNull(),
            "teamIdentifier": kv("TeamIdentifier") ?? NSNull(),
            "cdhash": kv("CDHash") ?? NSNull(),
            "authority": auths,
            "entitlements": entitlements,
            "lc_uuid": uuids,
            "cryptid": cryptid,
            "encrypted": cryptid != 0,
            "verifyOk": verify.ok,
            "verifyOutput": String(verify.out.prefix(500)),
            "sha256_file": sha256File(exe.path) ?? NSNull(),
        ]
    }

    /// Exports one bundle-relative file outside the bundle (bounded, hashed,
    /// symlink-escape-proof). Never writes INTO the bundle.
    ///
    /// - Parameter app: The installed .app URL.
    /// - Parameter src: Bundle-relative source path (no absolute, no `..` escape).
    /// - Parameter dest: Destination file URL (parent created; refuses existing
    ///   unless `overwrite`).
    /// - Parameter maxBytes: Size cap (default 50 MB).
    /// - Parameter overwrite: Replace an existing dest file.
    /// - Returns: `{src, dest, size, sha256_before, sha256_after}`.
    /// - Throws: `ToolRouter.bail` on escape, caps, or I/O failure.
    static func exportFile(app: URL, src: String, dest: URL,
                           maxBytes: Int = 50 * 1024 * 1024,
                           overwrite: Bool = false) throws -> [String: Any] {
        guard !src.isEmpty, !src.hasPrefix("/"), !src.split(separator: "/").contains("..") else {
            throw ToolRouter.bail("src must be bundle-relative without .. segments")
        }
        let srcURL = app.appendingPathComponent(src)
        // Realpath confinement: the symlink-resolved source must stay inside
        // the resolved bundle (kills symlink escape); the copy itself
        // preserves links as links.
        let bundleRoot = app.resolvingSymlinksInPath().path
        guard srcURL.resolvingSymlinksInPath().path.hasPrefix(bundleRoot) else {
            throw ToolRouter.bail("src escapes the bundle (symlink) - refused")
        }
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            throw ToolRouter.bail("no such bundle file: \(src)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: srcURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        guard size <= maxBytes else {
            throw ToolRouter.bail("file is \(size) bytes (cap \(maxBytes)) - raise maxBytes explicitly")
        }
        guard !FileManager.default.fileExists(atPath: dest.path) || overwrite else {
            throw ToolRouter.bail("dest exists: \(dest.path) - pass overwrite:true or pick another path")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: srcURL, to: dest)
        let before = sha256File(srcURL.path) ?? ""
        let after = sha256File(dest.path) ?? ""
        guard !before.isEmpty, before == after else {
            throw ToolRouter.bail("hash mismatch after copy (src intact, dest suspect) - dest left for inspection")
        }
        return ["src": src, "dest": dest.path, "size": size,
                "sha256_before": before, "sha256_after": after]
    }

    /// Zips a whole .app via `ditto -c -k --keepParent` (seal-preserving;
    /// never `--arch`) after the identity gate, with an identity sidecar next
    /// to (never inside) the zip.
    ///
    /// - Parameter app: The installed .app URL.
    /// - Parameter dest: Destination zip URL.
    /// - Parameter allowBrokenSeal: Export despite verify failure (labeled).
    /// - Parameter identity: Precomputed `appIdentity` (avoids recompute).
    /// - Returns: `{zip, sha256_zip, bytes, sealValid, identity}`.
    /// - Throws: `ToolRouter.bail` on FairPlay encryption, broken seal
    ///   (without override), or ditto failure.
    static func exportBundle(app: URL, dest: URL, allowBrokenSeal: Bool,
                             identity: [String: Any]) throws -> [String: Any] {
        if (identity["encrypted"] as? Bool) == true {
            throw ToolRouter.bail("ENCRYPTED_FAIRPLAY: main binary is FairPlay-encrypted (cryptid!=0) - "
                + "extracted bytes are ciphertext, useless for analysis. Metadata-only projection available.")
        }
        let sealOk = (identity["verifyOk"] as? Bool) ?? false
        guard sealOk || allowBrokenSeal else {
            throw ToolRouter.bail("SEAL_BROKEN: source fails codesign --verify --deep --strict - "
                + "pass allowBrokenSeal:true to export labeled output")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", app.path, dest.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { throw ToolRouter.bail("ditto failed to start") }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: dest.path) else {
            throw ToolRouter.bail("ditto archive creation failed (exit \(p.terminationStatus))")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        let sidecar = dest.deletingPathExtension().appendingPathExtension("identity.json")
        let sidecarObj = identity.merging(["bundleID": app.deletingPathExtension().lastPathComponent,
                                            "exportedAt": ISO8601DateFormatter().string(from: Date())]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: ContainerService.jsonSafe(sidecarObj),
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sidecar)
        }
        return ["zip": dest.path, "sha256_zip": sha256File(dest.path) ?? NSNull(),
                "bytes": bytes, "sealValid": sealOk,
                "sealLabel": sealOk ? "ok" : "SEAL_BROKEN",
                "identitySidecar": sidecar.path]
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
