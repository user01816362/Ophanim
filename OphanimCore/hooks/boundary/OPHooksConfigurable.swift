//
//  OPHooksConfigurable.swift
//  OphanimCore
//
//  User-specified ObjC boundary hooks (OPConfig.objcHooks). Swizzle an arbitrary (class, selector)
//  and log the call + its object arguments - capturing NSData as a body and NSString as a field.
//  This is the Tier-2 "language boundary" instrument: the high-value capture point for statically-
//  linked apps and SDKs is where their C/C++ hands decoded data to @objc code. Pure-Swift (non-@objc)
//  methods aren't reachable here - those need inline hooking.
//
//  Safety: only VOID methods are hooked (the dominant data-delivery/callback shape, e.g.
//  `-didReceiveData:`). Hooking a value-returning method with a void wrapper would corrupt the
//  return register, so those are skipped. Each (class, selector) is hooked at most once.
//

import Foundation
import ObjectiveC.runtime

enum OPConfigurableHooks {
    private static var installed = Set<String>()
    /// Saved originals for P5 bounded revert (key → method + IMP before our swizzle).
    private static var originals = [String: (m: Method, imp: IMP)]()

    /// Stable install key (also the removal-diff identity).
    ///
    /// - Parameter h: Configured ObjC hook.
    /// - Returns: "+/- [class selector]" identity string.
    private static func key(_ h: OPObjCHook) -> String {
        "\(h.classMethod ? "+" : "-")[\(h.className) \(h.selector)]"
    }

    /// P5 (bounded revert): restore the original IMP for every installed hook that is
    /// no longer wanted (removed from config or category-disabled). Main thread only,
    /// called from installUserHooks before install(). In-flight block calls hold their
    /// own `orig` capture and complete untouched; new calls hit the restored IMP.
    /// The discarded block IMP leaks (tiny, same as install already does).
    static func removeNotIn(_ hooks: [OPObjCHook]) {
        var wanted = Set<String>()
        for h in hooks where OPAgent.shared.isActive(h.category) { wanted.insert(key(h)) }
        for k in installed.subtracting(wanted) {
            if let saved = originals[k] {
                method_setImplementation(saved.m, saved.imp)
                originals.removeValue(forKey: k)
                OPAgent.shared.observe(OPEvent(category: .process, layer: .objc,
                    api: "ophanim.objcHook.remove",
                    summary: "\(k) → restored", fields: ["result": "restored", "key": k]))
            }
            installed.remove(k)
        }
    }

    /// Installs every configured ObjC boundary hook for active categories. Idempotent: re-runs
    /// on live reload pick up new hooks without re-installing (or re-logging) existing ones.
    static func install() {
        let hooks = OPAgent.shared.config.objcHooks
        guard !hooks.isEmpty else { return }
        // Aggregate failure counts (P4) — see OPHooksSwift.install.
        var failures: [String: Int] = [:]
        for h in hooks where OPAgent.shared.isActive(h.category) {
            let result = swizzle(h)
            // install() is re-run on every config live-reload to pick up newly added hooks; don't
            // re-log the ones already installed on a prior pass (swizzle() returns "already-installed").
            if result.hasPrefix("already") { continue }
            OPAgent.shared.observe(OPEvent(category: h.category, layer: .objc,
                api: "ophanim.objcHook.install",
                summary: "\(h.className).\(h.selector) → \(result)", fields: ["result": result]))
            if result != "ok" { failures[result, default: 0] += 1 }
        }
        if !failures.isEmpty {
            OPAgent.shared.observe(OPEvent(category: .process, layer: .objc,
                api: "ophanim.objcHook.installSummary",
                summary: "\(failures.values.reduce(0, +)) ObjC hook(s) failed to install",
                fields: Dictionary(uniqueKeysWithValues: failures.map { ($0.key, String($0.value)) })))
        }
    }

    /// Swizzles one configured (class, selector) to a logging block. Void methods only.
    ///
    /// - Parameter h: Configured ObjC hook.
    /// - Returns: "ok" on success, "already-installed" on re-run, otherwise a stable failure reason.
    @discardableResult
    private static func swizzle(_ h: OPObjCHook) -> String {
        let key = self.key(h)
        if installed.contains(key) { return "already-installed" }
        guard let base = NSClassFromString(h.className) else { return "class-not-found" }
        // P6: image scoping — skip classes from non-matching images (fail-open, counted).
        guard OPImageScope.matches(h.imageGlob, class: base) else { return "image-mismatch" }
        let cls: AnyClass = h.classMethod ? (object_getClass(base) ?? base) : base
        let sel = NSSelectorFromString(h.selector)
        guard let m = class_getInstanceMethod(cls, sel) else { return "method-not-found" }
        // Only hook void methods (don't corrupt a value return).
        let rt = method_copyReturnType(m)
        let isVoid = rt.pointee == 0x76 /* 'v' */
        free(rt)
        guard isVoid else { return "not-void" }
        let api = h.api ?? "\(h.className).\(h.selector)"
        let cat = h.category
        originals[key] = (m, method_getImplementation(m))
        let imp = imp_implementationWithBlock(makeBlock(max(0, min(3, h.args)), m, sel, api, cat))
        method_setImplementation(m, imp)
        installed.insert(key)
        return "ok"
    }

    /// Builds a void block of the requested object-arg arity that logs then forwards to the original.
    ///
    /// - Parameter argc: Object-arg count (clamped to 0...3 by the caller).
    /// - Parameter m: Method being swizzled (supplies the original IMP).
    /// - Parameter sel: Selector forwarded to the original.
    /// - Parameter api: API name for the event.
    /// - Parameter cat: Capture category gating the emit.
    /// - Returns: Block object installed as the new IMP.
    private static func makeBlock(_ argc: Int, _ m: Method, _ sel: Selector,
                                  _ api: String, _ cat: OPCategory) -> Any {
        switch argc {
        case 0:
            typealias F = @convention(c) (AnyObject, Selector) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject) -> Void = { o in
                if !emit(api, cat, []) { orig(o, sel) }
            }
            return blk
        case 1:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?) -> Void = { o, a in
                if !emit(api, cat, [a]) { orig(o, sel, a) }
            }
            return blk
        case 2:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { o, a, b in
                if !emit(api, cat, [a, b]) { orig(o, sel, a, b) }
            }
            return blk
        default:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { o, a, b, c in
                if !emit(api, cat, [a, b, c]) { orig(o, sel, a, b, c) }
            }
            return blk
        }
    }

    /// Logs the call and applies the rule decision. Returns true if the original should be SUPPRESSED
    /// (a `.blocked` rule); a `.delayed` rule sleeps first. (Void methods → no return to replace.)
    ///
    /// Hook bodies touch app objects (arg rendering above, KVC in rules below): an ObjC exception
    /// must fail open (disable the hook, note it for the crash record, log, run the original)
    /// instead of propagating into the app. Swift cannot catch ObjC exceptions, so the body runs
    /// through the ObjC wrapper.
    ///
    /// - Parameter api: API name for the event and fail-open identity.
    /// - Parameter cat: Capture category gating the emit.
    /// - Parameter args: Object arguments to render into fields.
    /// - Returns: True when the original call must be suppressed.
    @discardableResult
    private static func emit(_ api: String, _ cat: OPCategory, _ args: [AnyObject?]) -> Bool {
        guardLock.lock()
        let disabled = disabledAPIs.contains(api)
        guardLock.unlock()
        if disabled { return false }
        var fields: [String: String] = [:]
        var body: Data?
        for (i, a) in args.enumerated() {
            if let d = a as? NSData { body = d as Data; fields["arg\(i)"] = "<\(d.length) bytes>" }
            else if let s = a as? NSString { fields["arg\(i)"] = String((s as String).prefix(256)) }
            else if let o = a { fields["arg\(i)"] = String(describing: type(of: o)) }
            else { fields["arg\(i)"] = "nil" }
        }
        let ctx = OPCallContext(category: cat, layer: .objc, api: api, fields: fields)
        ctx.responseBody = body
        var suppressed = false
        var exName: NSString?
        var exReason: NSString?
        OPHookGuardRun({
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            if decision.disposition == .delayed && decision.delay > 0 {
                Thread.sleep(forTimeInterval: decision.delay)
            }
            suppressed = decision.disposition == .blocked
        }, &exName, &exReason)
        if exName != nil {
            guardLock.lock()
            disabledAPIs.insert(api)
            guardLock.unlock()
            OPCrashTrapNoteHook(api)
            let hookFields = ["api": api,
                              "exception": (exName as String?) ?? "?",
                              "reason": String((exReason as String?)?.prefix(256) ?? "")]
            let failure = OPCallContext(category: cat, layer: .objc, api: "\(api).hookFailure",
                                        fields: hookFields)
            OPAgent.shared.observe(OPAgent.shared.event(from: failure, decision: .observe,
                                                        summary: "hook threw; disabled"))
        }
        return suppressed
    }

    private static let guardLock = NSLock()
    private static var disabledAPIs = Set<String>()
}
