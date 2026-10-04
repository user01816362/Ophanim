//
//  HookTools.swift
//  Ophanim
//
//  Hook-installation tools. Codable hook-array decode + settings write.
//

import Foundation

/// Hook-installation tools. Codable hook-array decode + settings write.
///
/// Unlike most destructive tools these WRITERS honor dryRun only
/// when it is explicitly true (omitted = write, the historical contract —
/// agents already call set_*_hooks/set_rules without dryRun:false and flipping
/// the default would silently turn their writes into previews). Pass
/// dryRun:true to preview counts/validation without persisting.
enum HookTools {
    /// Crash-safe hook leases: `{bid::kind: {kind, expires, priorJSON}}`
    /// persisted beside the settings plists (never in OPConfig — synthesized
    /// decode fails on missing keys, so shared structs stay untouched).
    /// Every hook mutation sweeps expired leases first (restoring priors);
    /// an in-process timer reverts promptly while the server lives.
    private struct HookLeaseRecord: Codable {
        var kind: String
        var expires: Double
        var priorJSON: String
    }

    private static var leaseFile: URL {
        AppQueryService.settingsDir.appendingPathComponent("hook-leases.json")
    }

    private static func loadLeases() -> [String: HookLeaseRecord] {
        guard let data = try? Data(contentsOf: leaseFile),
              let obj = try? JSONDecoder().decode([String: HookLeaseRecord].self, from: data) else { return [:] }
        return obj
    }

    private static func saveLeases(_ leases: [String: HookLeaseRecord]) {
        try? FileManager.default.createDirectory(at: AppQueryService.settingsDir,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(leases) {
            try? data.write(to: leaseFile, options: .atomic)
        }
    }

    /// Reverts expired leases for an app before any hook mutation (crash-safe:
    /// priors live in the lease file, not memory).
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Returns: Note strings for reverted/orphaned leases.
    @discardableResult
    private static func sweepLeases(_ bid: String) -> [String] {
        var leases = loadLeases()
        var notes: [String] = []
        let now = Date().timeIntervalSince1970
        for key in leases.keys.sorted() where key.hasPrefix("\(bid)::") {
            guard let lease = leases[key], lease.expires <= now else { continue }
            let kind = lease.kind
            guard let jsonData = lease.priorJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) else {
                notes.append("lease for \(kind) expired but the prior array is undecodable - left as-is")
                leases.removeValue(forKey: key)
                continue
            }
            do {
                switch kind {
                case "objc":
                    let prior: [OPObjCHook] = try ToolRouter.decode(obj, label: "prior")
                    try SettingsStore.updateSettings(bid) { $0.ophanim.objcHooks = prior }
                case "swift":
                    let prior: [OPSwiftHook] = try ToolRouter.decode(obj, label: "prior")
                    try SettingsStore.updateSettings(bid) { $0.ophanim.swiftHooks = prior }
                case "inline":
                    let prior: [OPInlineHook] = try ToolRouter.decode(obj, label: "prior")
                    try SettingsStore.updateSettings(bid) { $0.ophanim.inlineHooks = prior }
                default: break
                }
                notes.append("lease for \(kind) expired - reverted to pre-lease hooks")
            } catch {
                notes.append("lease for \(kind) expired but revert failed: \(error.localizedDescription)")
            }
            leases.removeValue(forKey: key)
        }
        saveLeases(leases)
        return notes
    }

    /// Arms a time-boxed lease around the just-written hooks (fearless
    /// iteration on live apps): snapshots the prior array, stamps expiry,
    /// and schedules an in-process revert (the file sweep covers crashes).
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Parameter kind: `objc`, `swift`, or `inline`.
    /// - Parameter leaseSeconds: Lease length (>0 to arm).
    /// - Parameter priorJSON: The pre-write array as JSON text.
    private static func armLease(bid: String, kind: String, leaseSeconds: Double, priorJSON: String) {
        var leases = loadLeases()
        leases["\(bid)::\(kind)"] = HookLeaseRecord(kind: kind,
            expires: Date().timeIntervalSince1970 + leaseSeconds,
            priorJSON: priorJSON)
        saveLeases(leases)
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(max(leaseSeconds, 0.5) * 1_000_000_000))
            _ = sweepLeases(bid)
        }
    }

    /// Lease arg shared by the three writers + add_hooks (seconds, >0 arms).
    private static func leaseArg(_ args: [String: Any]) -> Double? {
        ToolRouter.coerceDouble(args, "leaseSeconds").flatMap { $0 > 0 ? $0 : nil }
    }
    /// Structural preflight shared by the three writers: within-batch
    /// duplicates, cross-tier overlap against CURRENT settings, and malformed
    /// shapes. Pure (no recon, no guest) so it runs identically in dryRun
    /// previews and as a note on writes. Existence stays agent-side
    /// (suggest_hooks + installSummary events); the write note points there.
    ///
    /// - Parameter bid: The app's bundle identifier.
    /// - Parameter kind: Writer kind for the note text.
    /// - Parameter keys: Normalized (identityKey, label) per new entry.
    /// - Returns: Note strings (empty when clean).
    private static func preflight(bid: String, kind: String,
                                  keys: [(id: String, label: String)]) -> [String] {
        var notes: [String] = []
        var seen: Set<String> = []
        for k in keys {
            if k.id.isEmpty {
                notes.append("\(kind): entry '\(k.label)' has an empty target - it will not install")
            } else if !seen.insert(k.id).inserted {
                notes.append("\(kind): duplicate target '\(k.id)' in this batch - installs once")
            }
        }
        if let cur = SettingsStore.appSettings(bid)?.ophanim {
            let live = Set(cur.objcHooks.map { "objc:\($0.className).\($0.selector)" })
                .union(cur.swiftHooks.map { "swift:\($0.className).\($0.method)" })
                .union(cur.inlineHooks.map { "inline:\($0.symbol ?? $0.address ?? $0.offset ?? $0.signature ?? $0.api)" })
            for k in keys where live.contains(k.id) {
                notes.append("\(kind): '\(k.id)' already installed - resend replaces in place")
            }
            let objcTargets = Set(cur.objcHooks.map { "\($0.className).\($0.selector)" })
            for k in keys where k.id.hasPrefix("swift:") && objcTargets.contains(String(k.id.dropFirst(6))) {
                notes.append("\(kind): '\(k.id)' overlaps an ObjC hook on the same method - expect double logging")
            }
        }
        return notes
    }

    /// Replaces the ObjC boundary hooks for an app.
    ///
    /// Swizzles (className, selector) pairs and logs the call plus its object
    /// args. Pure-Swift (non-@objc) methods are not reachable this way —
    /// those need inline hooking.
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPObjCHook] array,
    ///   required); `dryRun: true` previews the count without persisting.
    /// - Returns: Confirmation string, or dry-run JSON with `wouldSet`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
    // MARK: - Writes (explicit-true preview)

    static func setObjcHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPObjCHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        var notes = sweepLeases(bid)
        notes += preflight(bid: bid, kind: "objc",
                              keys: hooks.map { ("objc:\($0.className).\($0.selector)", "\($0.className).\($0.selector)") })
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "objc",
                                 "preflight": notes])
        }
        let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.objcHooks ?? []))
            .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
        try SettingsStore.updateSettings(bid) { $0.ophanim.objcHooks = hooks }
        if let lease = leaseArg(args) { armLease(bid: bid, kind: "objc", leaseSeconds: lease, priorJSON: priorJSON) }
        var msg = "Set \(hooks.count) ObjC boundary hook(s) for \(bid)."
        msg += notes.map { " NOTE: \($0)." }.joined()
        return msg + " Verify: tail_events search installSummary after ~2 s."
    }

    /// Replaces the native-Swift vtable hooks for an app.
    ///
    /// Patches an overridable Swift method's vtable slot to log the call and
    /// pass through. Reaches non-@objc Swift that ObjC swizzling cannot — but
    /// only methods dispatched through the vtable (polymorphic/cross-module;
    /// `-O` may devirtualize concrete calls).
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPSwiftHook] array,
    ///   required); `dryRun: true` previews the count without persisting.
    /// - Returns: Confirmation string, or dry-run JSON with `wouldSet`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
    static func setSwiftHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPSwiftHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        var notes = sweepLeases(bid)
        notes += preflight(bid: bid, kind: "swift",
                              keys: hooks.map { ("swift:\($0.className).\($0.method)", "\($0.className).\($0.method)") })
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "swift",
                                 "preflight": notes])
        }
        let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.swiftHooks ?? []))
            .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
        try SettingsStore.updateSettings(bid) { $0.ophanim.swiftHooks = hooks }
        if let lease = leaseArg(args) { armLease(bid: bid, kind: "swift", leaseSeconds: lease, priorJSON: priorJSON) }
        var msg = "Set \(hooks.count) native-Swift vtable hook(s) for \(bid)."
        msg += notes.map { " NOTE: \($0)." }.joined()
        return msg + " Verify: tail_events search installSummary after ~2 s."
    }

    /// Replaces the Tier-3 inline (machine-code) hooks for an app.
    ///
    /// arm64 only; gated behind `OPConfig.enableInlineHooks` (live code
    /// patching). When the gate is off the hooks persist but stay dormant,
    /// and the result carries a NOTE telling the agent how to arm them.
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPInlineHook] array,
    ///   required); `dryRun: true` previews the count and gate state without
    ///   persisting.
    /// - Returns: Confirmation string (plus arming NOTE when the gate is off),
    ///   or dry-run JSON with `wouldSet` and `gateOn`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
    static func setInlineHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPInlineHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        var notes = sweepLeases(bid)
        notes += preflight(bid: bid, kind: "inline",
                              keys: hooks.map { ("inline:\($0.symbol ?? $0.address ?? $0.offset ?? $0.signature ?? $0.api)", $0.api) })
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "inline",
                                 "gateOn": SettingsStore.appSettings(bid)?.ophanim.enableInlineHooks ?? false,
                                 "preflight": notes])
        }
        let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.inlineHooks ?? []))
            .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
        try SettingsStore.updateSettings(bid) { $0.ophanim.inlineHooks = hooks }
        if let lease = leaseArg(args) { armLease(bid: bid, kind: "inline", leaseSeconds: lease, priorJSON: priorJSON) }
        let gate = (SettingsStore.appSettings(bid)?.ophanim.enableInlineHooks ?? false)
        var msg = "Set \(hooks.count) inline hook(s) for \(bid)."
        msg += notes.map { " NOTE: \($0)." }.joined()
        msg += " Verify: tail_events search installSummary after ~2 s."
        return msg
            + (gate ? "" : " NOTE: inline hooks are OFF - call set_config enableInlineHooks=true to arm them.")
    }

    /// Merges hook entries into one tier (append, not replace): ends the
    /// wipe-by-resend hazard of the full-array writers. Same preflight +
    /// dryRun shape + optional lease as the writers.
    ///
    /// - Parameter args: `bundleID` (required); `kind` (`objc`/`swift`/
    ///   `inline`, required); `entries` (hook array, required);
    ///   `leaseSeconds` (optional trial lease); `dryRun: true` previews.
    /// - Returns: Dry-run JSON with `wouldAdd`, or confirmation with
    ///   `added`/`skipped` (+ lease note when armed).
    /// - Throws: `ToolRouter.bail` on bad kind or undecodable entries.
    static func addHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let kind = args["kind"] as? String, ["objc", "swift", "inline"].contains(kind) else {
            throw ToolRouter.bail("kind is required: objc | swift | inline")
        }
        guard args["entries"] != nil else { throw ToolRouter.bail("entries array is required") }
        var notes = sweepLeases(bid)
        switch kind {
        case "objc":
            let entries: [OPObjCHook] = try ToolRouter.decode(args["entries"]!, label: "entries")
            notes += preflight(bid: bid, kind: kind,
                               keys: entries.map { ("objc:\($0.className).\($0.selector)", "\($0.className).\($0.selector)") })
            var have = Set((SettingsStore.appSettings(bid)?.ophanim.objcHooks ?? []).map { "\($0.className).\($0.selector).\($0.classMethod)" })
            let fresh = entries.filter { have.insert("\($0.className).\($0.selector).\($0.classMethod)").inserted }
            if args["dryRun"] as? Bool == true {
                return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": kind,
                                     "wouldAdd": fresh.count, "preflight": notes])
            }
            let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.objcHooks ?? []))
                .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
            try SettingsStore.updateSettings(bid) { s in
                var cur = s.ophanim.objcHooks
                var keys = Set(cur.map { "\($0.className).\($0.selector).\($0.classMethod)" })
                for e in entries {
                    let k = "\(e.className).\(e.selector).\(e.classMethod)"
                    if let i = cur.firstIndex(where: { "\($0.className).\($0.selector).\($0.classMethod)" == k }) {
                        cur[i] = e
                    } else if keys.insert(k).inserted {
                        cur.append(e)
                    }
                }
                s.ophanim.objcHooks = cur
            }
            if let lease = leaseArg(args) { armLease(bid: bid, kind: kind, leaseSeconds: lease, priorJSON: priorJSON) }
            var msg = "Added \(fresh.count) ObjC hook(s) for \(bid) (merged, nothing removed)."
            msg += notes.map { " NOTE: \($0)." }.joined()
            return msg + " Verify: tail_events search installSummary after ~2 s."
        case "swift":
            let entries: [OPSwiftHook] = try ToolRouter.decode(args["entries"]!, label: "entries")
            notes += preflight(bid: bid, kind: kind,
                               keys: entries.map { ("swift:\($0.className).\($0.method)", "\($0.className).\($0.method)") })
            let have = Set((SettingsStore.appSettings(bid)?.ophanim.swiftHooks ?? []).map { "\($0.className).\($0.method)" })
            let fresh = entries.filter { !have.contains("\($0.className).\($0.method)") }
            if args["dryRun"] as? Bool == true {
                return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": kind,
                                     "wouldAdd": fresh.count, "preflight": notes])
            }
            let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.swiftHooks ?? []))
                .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
            try SettingsStore.updateSettings(bid) { s in
                var cur = s.ophanim.swiftHooks
                var keys = Set(cur.map { "\($0.className).\($0.method)" })
                for e in entries {
                    let k = "\(e.className).\(e.method)"
                    if let i = cur.firstIndex(where: { "\($0.className).\($0.method)" == k }) {
                        cur[i] = e
                    } else if keys.insert(k).inserted {
                        cur.append(e)
                    }
                }
                s.ophanim.swiftHooks = cur
            }
            if let lease = leaseArg(args) { armLease(bid: bid, kind: kind, leaseSeconds: lease, priorJSON: priorJSON) }
            var msg = "Added \(fresh.count) Swift hook(s) for \(bid) (merged, nothing removed)."
            msg += notes.map { " NOTE: \($0)." }.joined()
            return msg + " Verify: tail_events search installSummary after ~2 s."
        default:
            let entries: [OPInlineHook] = try ToolRouter.decode(args["entries"]!, label: "entries")
            let keyOf: (OPInlineHook) -> String = {
                "inline:\($0.symbol ?? $0.address ?? $0.offset ?? $0.signature ?? $0.api)"
            }
            notes += preflight(bid: bid, kind: kind, keys: entries.map { (keyOf($0), $0.api) })
            let have = Set((SettingsStore.appSettings(bid)?.ophanim.inlineHooks ?? []).map(keyOf))
            let fresh = entries.filter { !have.contains(keyOf($0)) }
            if args["dryRun"] as? Bool == true {
                return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": kind,
                                     "wouldAdd": fresh.count, "preflight": notes])
            }
            let priorJSON = ((try? JSONEncoder().encode(SettingsStore.appSettings(bid)?.ophanim.inlineHooks ?? []))
                .flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
            try SettingsStore.updateSettings(bid) { s in
                var cur = s.ophanim.inlineHooks
                var keys = Set(cur.map(keyOf))
                for e in entries {
                    let k = keyOf(e)
                    if let i = cur.firstIndex(where: { keyOf($0) == k }) {
                        cur[i] = e
                    } else if keys.insert(k).inserted {
                        cur.append(e)
                    }
                }
                s.ophanim.inlineHooks = cur
            }
            if let lease = leaseArg(args) { armLease(bid: bid, kind: kind, leaseSeconds: lease, priorJSON: priorJSON) }
            var msg = "Added \(fresh.count) inline hook(s) for \(bid) (merged, nothing removed)."
            msg += notes.map { " NOTE: \($0)." }.joined()
            return msg + " Verify: tail_events search installSummary after ~2 s."
        }
    }

    /// Reads back just the three hook arrays plus the inline gate.
    ///
    /// `get_config` already carries these arrays inside `instrumentation`,
    /// but agents managing hooks should not pay for the full hosting dump on
    /// every poll. Read-only.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `bundleID`, `enableInlineHooks`, `objcHooks`,
    ///   `swiftHooks`, `inlineHooks`.
    /// - Throws: `ToolRouter.bail` when `bundleID` is missing or the app has
    ///   no settings.
    // MARK: - Reads

    static func getHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let cfg = SettingsStore.config(bid) else {
            throw ToolRouter.bail("no settings found for \(bid)")
        }
        func asArray<T: Encodable>(_ value: [T]) -> [[String: Any]] {
            (try? JSONEncoder().encode(value))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        }
        return try ToolRouter.json([
            "bundleID": bid,
            "enableInlineHooks": cfg.enableInlineHooks,
            "objcHooks": asArray(cfg.objcHooks),
            "swiftHooks": asArray(cfg.swiftHooks),
            "inlineHooks": asArray(cfg.inlineHooks),
        ])
    }

    // MARK: - Surgical removal

    /// Remove one hook by array index (surgical alternative to full-array
    /// set_*_hooks; P5 reverts the dropped entry on next config poll).
    /// Destructive: dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` + `kind` (objc|swift|inline, required) + `index` (required).
    /// - Returns: JSON preview (with the entry) or removal confirmation.
    /// - Throws: `ToolRouter.bail` on unknown kind or out-of-range index.
    static func removeHook(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let kind = args["kind"] as? String,
              ["objc", "swift", "inline"].contains(kind) else {
            throw ToolRouter.bail("kind is required: objc, swift, or inline")
        }
        guard let index = ToolRouter.coerceInt(args, "index") else {
            throw ToolRouter.bail("index is required")
        }
        if ToolRouter.isDryRun(args) {
            let cfg = SettingsStore.config(bid)
            let count: Int
            switch kind {
            case "objc": count = cfg?.objcHooks.count ?? 0
            case "swift": count = cfg?.swiftHooks.count ?? 0
            default: count = cfg?.inlineHooks.count ?? 0
            }
            guard (0..<count).contains(index) else {
                throw ToolRouter.bail("index \(index) out of range (0..<\(count)) for \(kind) hooks on \(bid)")
            }
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": kind,
                                 "index": index, "wouldRemove": true])
        }
        var removed = false
        try SettingsStore.updateSettings(bid) { s in
            switch kind {
            case "objc":
                guard (0..<s.ophanim.objcHooks.count).contains(index) else { return }
                s.ophanim.objcHooks.remove(at: index); removed = true
            case "swift":
                guard (0..<s.ophanim.swiftHooks.count).contains(index) else { return }
                s.ophanim.swiftHooks.remove(at: index); removed = true
            default:
                guard (0..<s.ophanim.inlineHooks.count).contains(index) else { return }
                s.ophanim.inlineHooks.remove(at: index); removed = true
            }
        }
        guard removed else {
            throw ToolRouter.bail("index \(index) out of range for \(kind) hooks on \(bid)")
        }
        return try ToolRouter.json(["bundleID": bid, "kind": kind, "index": index, "removed": true])
    }
}
