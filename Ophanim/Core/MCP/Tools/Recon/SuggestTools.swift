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
}
