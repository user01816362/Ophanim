//
//  OPHooksInline.swift
//  OphanimCore
//
//  Swift side of the Tier-3 inline hook engine (C core in OPInline.{h,c,Asm.s}). Provides the
//  dispatcher the shared entry thunk calls into - it builds an OPCallContext from the saved CPU
//  registers, runs it through the policy engine (OPAgent.intercept), logs it, and maps the OPDecision
//  back onto RESUME/REPLACE (+ register edits). Also drives install from config (Phase 5) and a
//  dlsym self-test hook (used to validate the engine before the config path exists).
//
//  arm64 only. Live code patching is gated upstream behind an explicit per-app toggle.
//

import Foundation

/// Per-hook metadata, keyed by the hook id echoed through the C engine. Populated at install time
/// (before the code is patched, so reads on the dispatch path need no lock).
private struct OPInlineRec {
    var api: String
    var category: OPCategory
    var captureReturn: Bool
    var renderArgs: [Int: OPArgRender]   // arg index 0..7 → renderer
    var renderReturn: OPArgRender?
}

/// Safe dereference of an inline-hook register value as an ObjC object - runs on the app's thread
/// inside the intercepted prologue, so it must NEVER crash on a register that isn't actually an object.
/// Validation: non-null + 8-aligned, the isa word is readable, and the decoded class is a registered
/// runtime class (cached). Only then is it bridged. Anything else returns nil → caller falls back to hex.
enum OPObjc {
    /// Bridge a register value to an ObjC object only after C-side validation (`op_inline_is_objc`
    /// does the readable + registered-class check with raw pointers - Swift cast machinery on raw class
    /// values crashes on pathological classes, so it stays in C).
    static func object(_ raw: UInt64) -> AnyObject? {
        guard op_inline_is_objc(UInt(raw)), let p = UnsafeRawPointer(bitPattern: UInt(raw)) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
    }

    static func cString(_ raw: UInt64, max: Int = 1024) -> String {
        var buf = [CChar](repeating: 0, count: max)
        let n = op_inline_read_cstring(UInt(raw), &buf, max)
        return n > 0 ? String(cString: buf) : "0x" + String(raw, radix: 16)
    }
}

enum OPInlineHooks {
    private static var table: [UInt32: OPInlineRec] = [:]
    private static var nextID: UInt32 = 1
    /// Hooks whose install is settled (installed OR hard-failed) - never reattempted, so re-running
    /// install() on config live-reload doesn't leak ids/table entries or re-patch. Unresolved hooks
    /// are NOT marked done (their target symbol/module may load later), but are logged only once.
    private static var doneKeys = Set<String>()
    private static var unresolvedLogged = Set<String>()
    /// P5 (bounded revert): config-key → resolved target + hook id, so removal restores
    /// the saved original bytes. The harness self-test key never lands here (no config
    /// entry), so the self-test hook is never removed.
    private static var addrs = [String: UInt]()
    private static var ids = [String: UInt32]()

    /// P5 (bounded revert): restore original bytes for every installed hook that is no
    /// longer wanted (removed from config or category-disabled). Main thread only, from
    /// installUserHooks before install(). `op_inline_uninstall` restores the prologue but
    /// quarantines the page (never unmaps: a mid-trampoline thread still completes safely;
    /// new calls hit the restored original). Pages stay mapped — bounded by OP_MAX_HOOKS.
    static func removeNotIn(_ hooks: [OPInlineHook]) {
        var wanted = Set<String>()
        for h in hooks where OPAgent.shared.isActive(h.category) { wanted.insert(key(h)) }
        for k in Set(addrs.keys).subtracting(wanted) {
            if let addr = addrs[k] {
                let status = statusString(op_inline_uninstall(addr))
                OPAgent.shared.observe(OPEvent(category: .process, layer: .interpose,
                    api: "ophanim.inlineHook.remove",
                    summary: "\(k) → \(status)", fields: ["result": status, "key": k]))
            }
            if let hid = ids[k] { table.removeValue(forKey: hid) }
            addrs.removeValue(forKey: k)
            ids.removeValue(forKey: k)
            doneKeys.remove(k)
            unresolvedLogged.remove(k)
        }
    }

    /// Stable identity of a configured hook across reloads.
    private static func key(_ h: OPInlineHook) -> String {
        "\(h.api)|\(h.module ?? "")|\(h.symbol ?? "")|\(h.address ?? "")|\(h.offset ?? "")|\(h.signature ?? "")"
    }

    /// Install configured inline hooks (Phase 5 wires OPConfig.inlineHooks). For now this also runs a
    /// dlsym self-test against `optest_inline_target` when present in the host, so the engine can be
    /// validated end-to-end ahead of the config/MCP plumbing.
    static func install() {
        let cfg = OPAgent.shared.config
        guard cfg.enableInlineHooks else { return }

        // Aggregate failure counts (P4) — see OPHooksSwift.install. Config hooks
        // only; the harness self-test below keeps its own per-hook line.
        var failures: [String: Int] = [:]
        for hook in cfg.inlineHooks where OPAgent.shared.isActive(hook.category) {
            let k = key(hook)
            if doneKeys.contains(k) { continue }          // already installed or hard-failed: don't reattempt
            let addr = resolve(hook)
            if addr == 0 {
                // Transient (symbol/module may load later): retry on a future reload, but log once.
                if unresolvedLogged.insert(k).inserted {
                    logInstall(hook.api, 0, "unresolved")
                    failures["unresolved", default: 0] += 1
                }
                continue
            }
            let id = register(api: hook.api, category: hook.category, captureReturn: hook.captureReturn,
                              renderArgs: parseRenderArgs(hook.renderArgs), renderReturn: hook.renderReturn)
            let status = statusString(op_inline_install(addr, id))
            logInstall(hook.api, addr, status)
            if status != "ok", !status.hasPrefix("already") { failures[status, default: 0] += 1 }
            // Record revert info only on success: any other status leaves no live patch
            // of ours behind ("already-hooked" belongs to a co-installed patch — uninstalling
            // it on our removal would clobber someone else's hook).
            if status == "ok" || status.hasPrefix("ok ") {
                addrs[k] = addr
                ids[k] = id
            }
            doneKeys.insert(k)                            // resolved → installed or hard-failed; settle it
        }
        if !failures.isEmpty {
            OPAgent.shared.observe(OPEvent(category: .process, layer: .interpose,
                api: "ophanim.inlineHook.installSummary",
                summary: "\(failures.values.reduce(0, +)) inline hook(s) failed to install",
                fields: Dictionary(uniqueKeysWithValues: failures.map { ($0.key, String($0.value)) })))
        }

        // self-test (harness only): follow the @_cdecl thunk to the real body and hook it (captureReturn
        // on, so the leave path - BL original → log return - is exercised too).
        if doneKeys.insert("__selftest__").inserted {
            let t = op_inline_follow_thunk(op_inline_resolve_symbol("optest_inline_target"))
            if t != 0 {
                let id = register(api: "optest_inline_target", category: .process, captureReturn: true,
                                  renderArgs: [:], renderReturn: nil)
                logInstall("optest_inline_target", t, statusString(op_inline_install(t, id)))
            }
        }
    }

    /// Parse a {"x2":"nsdata", …} map into {2: .nsdata, …}. Ignores malformed keys.
    private static func parseRenderArgs(_ m: [String: OPArgRender]?) -> [Int: OPArgRender] {
        guard let m = m else { return [:] }
        var out: [Int: OPArgRender] = [:]
        for (k, v) in m {
            if k.hasPrefix("x"), let i = Int(k.dropFirst()), (0...7).contains(i) { out[i] = v }
        }
        return out
    }

    /// Resolve a hook's target address. Priority: absolute address, exported symbol, module+offset,
    /// module+signature. `followThunk` chases a leading unconditional B (common for exported Swift).
    private static func resolve(_ h: OPInlineHook) -> UInt {
        if let a = h.address, let v = parseUInt(a) { return UInt(v) }
        if let s = h.symbol, !s.isEmpty {
            let a = op_inline_resolve_symbol(s)
            return h.followThunk ? op_inline_follow_thunk(a) : a
        }
        if let off = h.offset, let v = parseUInt(off) {
            let a = op_inline_resolve_module_offset(h.module ?? "", v)
            return (a != 0 && h.followThunk) ? op_inline_follow_thunk(a) : a
        }
        if let sig = h.signature, !sig.isEmpty {
            let pat = parseSignature(sig)
            guard !pat.isEmpty else { return 0 }
            let a = pat.withUnsafeBufferPointer {
                op_inline_resolve_signature(h.module ?? "", $0.baseAddress, $0.count)
            }
            return (a != 0 && h.followThunk) ? op_inline_follow_thunk(a) : a
        }
        return 0
    }

    private static func logInstall(_ api: String, _ addr: UInt, _ result: String) {
        OPAgent.shared.observe(OPEvent(category: .process, layer: .interpose,
            api: "ophanim.inlineHook.install",
            summary: "\(api) @ 0x\(String(addr, radix: 16)) → \(result)",
            fields: ["result": result, "target": "0x\(String(addr, radix: 16))", "label": api]))
    }

    /// Parse a wildcard byte pattern ("1F 20 ?? D5") to ints; wildcard byte = 0x100 (matches any).
    private static func parseSignature(_ s: String) -> [Int32] {
        var out: [Int32] = []
        for tok in s.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if tok == "??" || tok == "?" { out.append(0x100) }
            else if let b = UInt8(tok, radix: 16) { out.append(Int32(b)) }
            else { return [] }   // malformed
        }
        return out
    }

    private static func parseUInt(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt64(t.dropFirst(2), radix: 16) }
        return UInt64(t)
    }

    private static func register(api: String, category: OPCategory, captureReturn: Bool,
                                 renderArgs: [Int: OPArgRender], renderReturn: OPArgRender?) -> UInt32 {
        let id = nextID; nextID += 1
        table[id] = OPInlineRec(api: api, category: category, captureReturn: captureReturn,
                                renderArgs: renderArgs, renderReturn: renderReturn)
        return id
    }

    /// Apply a register's renderer into the call context (deref as object → body/field, or C string).
    /// `into` distinguishes the request side (arg regs → requestBody) from the leave side (responseBody).
    private static func render(_ raw: UInt64, _ r: OPArgRender, key: String,
                               cc: OPCallContext, asResponse: Bool) {
        switch r {
        case .nsdata:
            if let obj = OPObjc.object(raw), let d = obj as? NSData {
                if asResponse { cc.responseBody = d as Data } else { cc.requestBody = d as Data }
                cc.fields[key] = "<\(d.length) bytes>"
            }
        case .nsstring:
            if let obj = OPObjc.object(raw), let s = obj as? NSString { cc.fields[key] = s as String }
        case .objcDesc:
            if let obj = OPObjc.object(raw) { cc.fields[key] = String(String(describing: obj).prefix(512)) }
        case .cString:
            if raw != 0 { cc.fields[key] = OPObjc.cString(raw) }
        }
    }

    private static func statusString(_ s: op_inline_status_t) -> String {
        switch s {
        case OP_INLINE_OK:              return "ok"
        case OP_INLINE_ERR_ALREADY:     return "already-hooked"
        case OP_INLINE_ERR_ARM64E:      return "refused-arm64e"
        case OP_INLINE_ERR_NOT_EXEC:    return "not-executable"
        case OP_INLINE_ERR_UNRELOCATABLE: return "unrelocatable-prologue"
        case OP_INLINE_ERR_RANGE:       return "no-trampoline-in-range"
        case OP_INLINE_ERR_NOMEM:       return "alloc-failed"
        default:                        return "bad-arg"
        }
    }

    /// Called from the shared entry thunk (via op_inline_dispatch). Returns OP_INLINE_RESUME(0) /
    /// OP_INLINE_REPLACE(1). modifyArgs edits land in x0–x7 before RESUME; REPLACE returns
    /// to the caller with x0 set, skipping the original entirely.
    static func dispatch(_ hookID: UInt32, _ ctx: UnsafeMutablePointer<OPCpuContext>) -> Int32 {
        guard let rec = table[hookID] else { return Int32(OP_INLINE_RESUME) }
        // x[31] is the first field of OPCpuContext, so the struct base aliases the GP register file.
        let regs = UnsafeMutableRawPointer(ctx).assumingMemoryBound(to: UInt64.self)
        var result = Int32(OP_INLINE_RESUME)
        OPReentry.guarded {
            let cc = OPCallContext(category: rec.category, layer: .interpose, api: rec.api,
                fields: ["x0": hex(regs[0]), "x1": hex(regs[1]),
                         "x2": hex(regs[2]), "x3": hex(regs[3]), "dispatch": "inline"])
            // opt-in: render selected arg registers as ObjC objects / C strings (safe deref)
            for (idx, r) in rec.renderArgs where idx < 8 {
                render(regs[idx], r, key: "x\(idx)", cc: cc, asResponse: false)
            }
            let decision = OPAgent.shared.intercept(cc)
            OPAgent.shared.observe(OPAgent.shared.event(from: cc, decision: decision))
            // Map the rule decision onto the engine's RESUME/REPLACE protocol. RESUME runs the
            // original (with any handler-edited arg registers); REPLACE returns to the caller with
            // x0 set, skipping the original entirely.
            switch decision.disposition {
            case .observed:
                // run the original; if the hook wants its return value, route through the leave path
                result = rec.captureReturn ? Int32(OP_INLINE_RESUME_LEAVE) : Int32(OP_INLINE_RESUME)
            case .argsModified:
                // P2: entry-arg edits are honored on the RESUME path (previously dropped).
                // Explicit per-register rewrites first; else the first up-to-8 body bytes
                // load into x0 (documented modifyArgs contract for inline hooks).
                // Malformed keys/values are ignored fail-open — never a crash.
                if let edits = decision.cannedArgs {
                    for (k, v) in edits {
                        if k.hasPrefix("x"), let i = Int(k.dropFirst()), (0...7).contains(i),
                           let n = parseReturn(v) { regs[i] = n }
                    }
                } else if let body = decision.replacementBody, !body.isEmpty {
                    regs[0] = body.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                }
                result = rec.captureReturn ? Int32(OP_INLINE_RESUME_LEAVE) : Int32(OP_INLINE_RESUME)
            case .blocked:
                regs[0] = 0
                result = Int32(OP_INLINE_REPLACE)
            case .returnReplaced:
                if let v = decision.cannedReturnValue, let n = parseReturn(v) { regs[0] = n }
                result = Int32(OP_INLINE_REPLACE)
            case .faulted:
                regs[0] = UInt64(bitPattern: Int64(decision.faultErrorCode ?? -1))
                result = Int32(OP_INLINE_REPLACE)
            case .delayed:
                if decision.delay > 0 { Thread.sleep(forTimeInterval: decision.delay) }
                result = Int32(OP_INLINE_RESUME)
            }
        }
        return result
    }

    /// Called after the original runs (RESUME_LEAVE). Logs its return value; a matching returnReplaced
    /// rule transforms it (here it applies AFTER observing the real result, unlike the entry REPLACE).
    static func dispatchLeave(_ hookID: UInt32, _ ctx: UnsafeMutablePointer<OPCpuContext>) {
        guard let rec = table[hookID] else { return }
        let regs = UnsafeMutableRawPointer(ctx).assumingMemoryBound(to: UInt64.self)
        OPReentry.guarded {
            let cc = OPCallContext(category: rec.category, layer: .interpose, api: rec.api,
                fields: ["return": hex(regs[0]), "dispatch": "inline-leave"])
            // opt-in: render the return value (x0) as an ObjC object / C string
            if let rr = rec.renderReturn { render(regs[0], rr, key: "return", cc: cc, asResponse: true) }
            let decision = OPAgent.shared.intercept(cc)
            OPAgent.shared.observe(OPAgent.shared.event(from: cc, decision: decision,
                                                        summary: "returned \(hex(regs[0]))"))
            if decision.disposition == .returnReplaced,
               let v = decision.cannedReturnValue, let n = parseReturn(v) { regs[0] = n }
        }
    }

    private static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    /// Parse a canned return value: decimal, or 0x-prefixed hex (signed values wrap into UInt64).
    private static func parseReturn(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return UInt64(t.dropFirst(2), radix: 16) }
        if let i = Int64(t) { return UInt64(bitPattern: i) }
        return UInt64(t)
    }
}

/// C entry points invoked by OPInlineAsm.s.
@_cdecl("op_inline_dispatch")
public func op_inline_dispatch(_ hookID: UInt32, _ ctx: UnsafeMutablePointer<OPCpuContext>) -> Int32 {
    return OPInlineHooks.dispatch(hookID, ctx)
}

@_cdecl("op_inline_dispatch_leave")
public func op_inline_dispatch_leave(_ hookID: UInt32, _ ctx: UnsafeMutablePointer<OPCpuContext>) {
    OPInlineHooks.dispatchLeave(hookID, ctx)
}
