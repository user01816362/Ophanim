import Foundation

/// frida-trace-shaped hook suggester: keyword → draft ObjC boundary hooks.
/// Host-only synthesizer over the EXISTING live inventory reads (zero guest
/// change). Pairings come exclusively from `inspect_class_detail` (class +
/// method + arity + return type in one record) — never from crossing static
/// selector lists with class lists, which would hook wrong methods. Only
/// void methods with 0–3 args are drafted (the engine's void-only gate);
/// everything else is counted as skipped with its reason.
enum SuggestTools {
    static func suggestHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let keyword = args["keyword"] as? String, !keyword.isEmpty else {
            throw ToolRouter.bail("keyword is required (e.g. 'didReceive', 'Response')")
        }
        let kind = (args["kind"] as? String).flatMap { ["objc", "swift", "inline"].contains($0) ? $0 : nil } ?? "objc"
        if kind == "swift" { return try suggestSwiftHooks(bid, args, keyword: keyword) }
        if kind == "inline" { return try suggestInlineHooks(bid, args, keyword: keyword) }
        let category = (args["category"] as? String).flatMap(OPCategory.init(rawValue:)) ?? .process
        let maxClasses = min(ToolRouter.coerceInt(args, "maxClasses") ?? 5, 10)
        let maxHooks = min(ToolRouter.coerceInt(args, "maxHooks") ?? 10, 20)

        // Live inventory only: static strings cannot pair selectors to classes.
        let inv = try InspectTools.classInventory(bid, filter: keyword, limit: maxClasses)
        guard (inv["source"] as? String) == "live",
              let classes = inv["classes"] as? [String], !classes.isEmpty else {
            throw ToolRouter.bail("no live classes match '\(keyword)' - launch with Agent Mode for the live runtime inventory")
        }
        var drafts: [OPObjCHook] = []
        var skipped: [String: Int] = [:]
        for cls in classes.prefix(maxClasses) {
            let rsp = try InspectControl.transact(bundleID: bid, op: .classDetail, className: cls)
            guard let detail = rsp.classDetail else {
                skipped["detail-failed", default: 0] += 1
                continue
            }
            let groups = [(detail.methods, false), (detail.classMethods, true)]
            for (methods, isClass) in groups {
                for m in methods where m.sel.localizedCaseInsensitiveContains(keyword) {
                    if drafts.count >= maxHooks {
                        skipped["over-cap", default: 0] += 1
                        continue
                    }
                    guard m.ret == "v" else { skipped["non-void", default: 0] += 1; continue }
                    guard (0...3).contains(m.args) else { skipped["arity", default: 0] += 1; continue }
                    drafts.append(OPObjCHook(className: cls, selector: m.sel, args: m.args,
                                            classMethod: isClass, category: category))
                }
            }
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "keyword": keyword,
                                 "drafts": drafts.map(draftDict),
                                 "skipped": skipped, "count": drafts.count])
        }
        var added = 0
        try SettingsStore.updateSettings(bid) { s in
            var have = Set(s.ophanim.objcHooks.map { "\($0.className).\($0.selector).\($0.classMethod)" })
            for d in drafts {
                let k = "\(d.className).\(d.selector).\(d.classMethod)"
                if have.insert(k).inserted { s.ophanim.objcHooks.append(d); added += 1 }
            }
        }
        return "Suggested \(drafts.count) hook(s) for '\(keyword)'; applied \(added) new (rest already installed)."
    }

    private static func draftDict(_ h: OPObjCHook) -> [String: Any] {
        ["className": h.className, "selector": h.selector, "args": h.args,
         "classMethod": h.classMethod, "category": h.category.rawValue]
    }

    /// Static-driven Swift vtable candidates: mangled↔demangled class pairs
    /// filtered by keyword, each paired with the caller-supplied method
    /// substring (no cross-product pairing — the class comes from one
    /// symbol, the method from the operator). Labeled `likely`: static
    /// names cannot prove vtable dispatch; verify via installSummary.
    /// Same omitted-writes contract as the ObjC path.
    private static func suggestSwiftHooks(_ bid: String, _ args: [String: Any], keyword: String) throws -> String {
        guard keyword.range(of: #"[^A-Za-z0-9_.\-:]"#, options: .regularExpression) == nil else {
            throw ToolRouter.bail("keyword contains unsafe characters (allowed: letters, digits, _ . - :)")
        }
        guard let method = args["method"] as? String, !method.isEmpty else {
            throw ToolRouter.bail("method substring is required for kind=swift (e.g. 'play', 'didReceive')")
        }
        let category = (args["category"] as? String).flatMap(OPCategory.init(rawValue:)) ?? .process
        let maxHooks = min(ToolRouter.coerceInt(args, "maxHooks") ?? 10, 20)
        let pairs = AppQueryService.swiftClassPairs(bid, keyword).prefix(maxHooks)
        guard !pairs.isEmpty else {
            throw ToolRouter.bail("no Swift classes match '\(keyword)' - try all_symbols kind=classes")
        }
        let drafts = pairs.map { p -> [String: Any] in
            ["className": p["mangled"] ?? "", "method": method, "category": category.rawValue,
             "confidence": "likely", "note": "static-derived: verify via installSummary after ~2 s"]
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": "swift",
                                 "drafts": drafts, "count": drafts.count])
        }
        var added = 0
        try SettingsStore.updateSettings(bid) { s in
            var have = Set(s.ophanim.swiftHooks.map { "\($0.className).\($0.method)" })
            for d in drafts {
                let cls = d["className"] as? String ?? ""
                let k = "\(cls).\(method)"
                if have.insert(k).inserted {
                    s.ophanim.swiftHooks.append(OPSwiftHook(className: cls, method: method, category: category))
                    added += 1
                }
            }
        }
        return "Suggested \(drafts.count) Swift hook(s) for '\(keyword)'/\(method); applied \(added) new. Verify: tail_events search installSummary after ~2 s."
    }

    /// Static-driven inline drafts: scan_signature hits become
    /// module+offset anchors (zero-code-tracer analogue). Pattern supplied
    /// by the operator (string_xrefs finds data refs, scan finds code).
    /// Same omitted-writes contract as the ObjC path.
    private static func suggestInlineHooks(_ bid: String, _ args: [String: Any], keyword: String) throws -> String {
        guard let exe = AppQueryService.appExecutable(bid) else {
            throw ToolRouter.bail("no executable for \(bid)")
        }
        let bytes = ReconView.parsePattern(keyword)
        guard !bytes.isEmpty else {
            throw ToolRouter.bail("keyword must be a hex pattern for kind=inline, e.g. '1F 20 ?? D5' (use string_xrefs to locate data first)")
        }
        let category = (args["category"] as? String).flatMap(OPCategory.init(rawValue:)) ?? .process
        let maxHooks = min(ToolRouter.coerceInt(args, "maxHooks") ?? 10, 20)
        let (hits, _) = ReconView.scan(url: exe, pattern: bytes)
        guard !hits.isEmpty else {
            throw ToolRouter.bail("pattern matched no code offsets - refine the pattern")
        }
        let module = exe.deletingPathExtension().lastPathComponent
        let drafts = hits.prefix(maxHooks).map { hit -> [String: Any] in
            let off = hit.split(separator: " ").last.map(String.init) ?? "0x0"
            return ["api": "xref-pattern:\(keyword)@\(off)", "module": module, "offset": off,
                    "category": category.rawValue, "confidence": "likely",
                    "note": "static-derived code anchor: verify via installSummary after ~2 s"]
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "kind": "inline",
                                 "drafts": Array(drafts), "count": drafts.count])
        }
        var added = 0
        try SettingsStore.updateSettings(bid) { s in
            var have = Set(s.ophanim.inlineHooks.map { "\($0.module ?? ""):\($0.offset ?? $0.symbol ?? $0.address ?? "")" })
            for d in drafts {
                let k = "\(module):\(d["offset"] as? String ?? "")"
                if have.insert(k).inserted {
                    var h = OPInlineHook(api: d["api"] as? String ?? k, category: category)
                    h.module = module
                    h.offset = d["offset"] as? String
                    s.ophanim.inlineHooks.append(h)
                    added += 1
                }
            }
        }
        return "Suggested \(drafts.count) inline hook(s) for pattern '\(keyword)'; applied \(added) new. Verify: tail_events search installSummary after ~2 s."
    }
}
