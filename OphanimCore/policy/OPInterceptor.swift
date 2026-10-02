//
//  OPInterceptor.swift
//  OphanimCore
//
//  The policy engine. Each hook builds an OPCallContext, asks the interceptor for a decision,
//  applies it, then emits the resulting event. Observe-by-default: with no matching rule the
//  decision is `.observe` and the original call runs untouched.
//

import Foundation
import JavaScriptCore

/// Mutable description of an in-flight call handed to the interceptor (and to JS scripts).
///
/// Guest-only: lives in the injected agent, never in the host app. `init`
/// defaults keep hook call sites to one line; `stringifiedArgs` is the
/// search target for `OPMatcher.argContains`.
///
/// - Parameter category: Routing bucket for the call.
/// - Parameter layer: Which instrumentation layer produced it.
/// - Parameter api: API name.
/// - Parameter fields: Structured key/values.
/// - Parameter host: Network host, when known.
/// - Parameter url: Full URL, when known.
/// - Parameter path: Filesystem path, when known.
/// - Parameter requestBody: Outbound payload, when captured.
/// - Parameter responseBody: Inbound payload, when captured.
public final class OPCallContext {
    public let category: OPCategory
    public let layer: OPCaptureLayer
    public let api: String
    public var fields: [String: String]
    public var host: String?
    public var url: String?
    public var path: String?
    public var requestBody: Data?
    public var responseBody: Data?

    public init(category: OPCategory, layer: OPCaptureLayer, api: String,
                fields: [String: String] = [:], host: String? = nil, url: String? = nil,
                path: String? = nil, requestBody: Data? = nil, responseBody: Data? = nil) {
        self.category = category; self.layer = layer; self.api = api
        self.fields = fields; self.host = host; self.url = url; self.path = path
        self.requestBody = requestBody; self.responseBody = responseBody
    }

    /// Any-arg substring search target used by OPMatcher.argContains.
    var stringifiedArgs: String {
        ([api, host, url, path].compactMap { $0 } + fields.map { "\($0)=\($1)" }).joined(separator: " ")
    }
}

/// Outcome of consulting the rules: what to do plus any replacement payload.
///
/// Guest-only. `observe` is the shared observe-by-default value: no match in
/// `decide` means the original call runs untouched.
public struct OPDecision {
    public var disposition: OPDisposition
    public var matchedRuleID: String?
    public var replacementBody: Data?
    public var replacementHeaders: [String: String]?
    public var replacementStatus: Int?
    public var cannedReturnValue: String?
    public var cannedArgs: [String: String]?   // inline RESUME-path register rewrites (x0–x7)
    public var delay: TimeInterval
    public var faultErrorCode: Int?

    public static let observe = OPDecision(disposition: .observed, matchedRuleID: nil,
                                           replacementBody: nil, replacementHeaders: nil,
                                           replacementStatus: nil, cannedReturnValue: nil,
                                           cannedArgs: nil,
                                           delay: 0, faultErrorCode: nil)
}

/// The policy engine: match each call against the rules, decide, emit.
///
/// Guest-only (built into the injected agent, not the host app). Thread-safe:
/// `decide()` runs on many threads; JS evaluation serializes on `jsLock` and
/// per-rule script state resets on every config reload (fresh interceptor).
public final class OPInterceptor {
    private let rules: [OPRule]
    private let jsContext: JSContext?
    private let jsLock = NSLock()   // JSContext is not thread-safe; decide() runs on many threads
    /// Per-rule persistent script state (P1): rule id → string dict. Touched only
    /// inside runScript (under jsLock). Fresh on every config reload (the agent
    /// rebuilds the interceptor per load), capped per rule so a runaway script
    /// can't grow memory: 32 keys, 256 chars per value, deterministic keep-first.
    private var ruleState: [String: [String: String]] = [:]
    private static let maxStateKeys = 32
    private static let maxStateValueChars = 256

    /// Builds the engine for one config generation.
    ///
    /// Disabled rules are filtered once here (not per call). A `JSContext`
    /// is stood up only when some rule actually needs scripting.
    ///
    /// - Parameter rules: Full rule list; disabled entries are dropped.
    public init(rules: [OPRule]) {
        self.rules = rules.filter { $0.enabled }
        // Only stand up a JS context if some rule actually needs scripting.
        if rules.contains(where: { $0.action.kind == .script }) {
            self.jsContext = JSContext()
            self.jsContext?.exceptionHandler = { _, exc in
                NSLog("[Ophanim] JS rule error: \(exc?.toString() ?? "unknown")")
            }
        } else {
            self.jsContext = nil
        }
    }

    /// Resolves a decision for a call. First matching rule wins.
    ///
    /// Observe-by-default: no match returns `.observe` and the original call
    /// runs untouched. Stays synchronous — no host round-trip (scripts run
    /// in-process under `jsLock`).
    ///
    /// - Parameter ctx: The in-flight call description.
    /// - Returns: The disposition plus any replacement payload.
    public func decide(_ ctx: OPCallContext) -> OPDecision {
        for rule in rules where matches(rule.match, ctx) {
            return apply(rule, ctx)
        }
        return .observe
    }

    // MARK: - Matching

    /// Whether every present matcher field agrees with the call (AND).
    ///
    /// - Parameter m: Matcher under test.
    /// - Parameter ctx: The in-flight call description.
    /// - Returns: True only when all present fields match.
    private func matches(_ m: OPMatcher, _ ctx: OPCallContext) -> Bool {
        if let cats = m.categories, !cats.contains(ctx.category) { return false }
        if let g = m.apiGlob, !OPGlob.match(g, ctx.api) { return false }
        if let g = m.hostGlob, !(ctx.host.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let g = m.urlGlob, !(ctx.url.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let g = m.pathGlob, !(ctx.path.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let sub = m.argContains, !ctx.stringifiedArgs.localizedCaseInsensitiveContains(sub) { return false }
        return true
    }

    // MARK: - Action application

    /// Converts a matched static rule into a decision.
    ///
    /// `.script` rules divert to `runScript`; everything else maps
    /// one-to-one onto a disposition plus its payload fields.
    ///
    /// - Parameter rule: The matched rule.
    /// - Parameter ctx: The in-flight call description (read by script rules).
    /// - Returns: The decision for this rule.
    private func apply(_ rule: OPRule, _ ctx: OPCallContext) -> OPDecision {
        let a = rule.action
        switch a.kind {
        case .observe:
            return decision(.observed, rule)
        case .block:
            return decision(.blocked, rule)
        case .delay:
            var d = decision(.delayed, rule)
            d.delay = TimeInterval(a.delayMilliseconds ?? 0) / 1000.0
            return d
        case .fault:
            var d = decision(.faulted, rule)
            d.faultErrorCode = a.faultErrorCode
            return d
        case .modifyArgs:
            var d = decision(.argsModified, rule)
            d.replacementBody = a.replacementBodyBase64.flatMap { Data(base64Encoded: $0) }
            d.replacementHeaders = a.replacementHeaders
            d.cannedArgs = a.cannedArgs
            return d
        case .replaceReturn:
            var d = decision(.returnReplaced, rule)
            d.replacementBody = a.replacementBodyBase64.flatMap { Data(base64Encoded: $0) }
            d.replacementHeaders = a.replacementHeaders
            d.replacementStatus = a.replacementStatus
            d.cannedReturnValue = a.cannedReturnValue
            return d
        case .script:
            return runScript(a.script ?? "", rule, ctx)
        }
    }

    private func decision(_ disp: OPDisposition, _ rule: OPRule) -> OPDecision {
        var d = OPDecision.observe
        d.disposition = disp
        d.matchedRuleID = rule.id
        return d
    }

    /// Evaluates a JS rule against a call.
    ///
    /// The script sees `ctx` and may set `ctx.replacementBody` (base64),
    /// `ctx.replacementStatus`, `ctx.block = true`, `ctx.returnValue`,
    /// per-register `ctx.x0`…`ctx.x7` (inline arg edits; arg-only scripts
    /// resolve to `.argsModified` — run the original with edited regs — NOT
    /// `.returnReplaced`, which would skip the original entirely, unless a
    /// return-style output is also set), or `ctx.state.*` (per-rule
    /// persistent strings, capped — survives across calls until the next
    /// config reload). Reads: `ctx.method`, `ctx.statusCode` (-1 when
    /// absent), plus the string fields. Runs under `jsLock`; a missing
    /// `JSContext` (no script rules configured) resolves to `.observed`.
    ///
    /// - Parameter source: JS rule body.
    /// - Parameter rule: The matched rule (owns the `ctx.state` slot).
    /// - Parameter ctx: The in-flight call description.
    /// - Returns: The script's decision, or `.observed` when it changed nothing.
    private func runScript(_ source: String, _ rule: OPRule, _ ctx: OPCallContext) -> OPDecision {
        guard let js = jsContext else { return decision(.observed, rule) }
        jsLock.lock(); defer { jsLock.unlock() }
        let bridge: [String: Any] = [
            "category": ctx.category.rawValue,
            "api": ctx.api,
            "host": ctx.host as Any,
            "url": ctx.url as Any,
            "path": ctx.path as Any,
            "method": ctx.fields["method"] ?? "",
            "statusCode": Int(ctx.fields["status"] ?? "") ?? -1,
            "requestBodyBase64": ctx.requestBody?.base64EncodedString() as Any,
            "responseBodyBase64": ctx.responseBody?.base64EncodedString() as Any,
            "fields": ctx.fields,
            "state": ruleState[rule.id] ?? [:],
            "block": false
        ]
        js.setObject(bridge, forKeyedSubscript: "ctx" as NSString)
        js.evaluateScript(source)
        guard let out = js.objectForKeyedSubscript("ctx") else { return decision(.observed, rule) }

        if out.objectForKeyedSubscript("block")?.toBool() == true {
            return decision(.blocked, rule)
        }
        var changed = false
        var d = decision(.returnReplaced, rule)
        if let b64 = out.objectForKeyedSubscript("replacementBody")?.toString(), !b64.isEmpty, b64 != "undefined",
           let data = Data(base64Encoded: b64) {
            d.replacementBody = data; changed = true
        }
        if let status = out.objectForKeyedSubscript("replacementStatus"), status.isNumber {
            d.replacementStatus = Int(status.toInt32()); changed = true
        }
        if let rv = out.objectForKeyedSubscript("returnValue")?.toString(), rv != "undefined", !rv.isEmpty {
            d.cannedReturnValue = rv; changed = true
        }
        // Per-register arg edits (x0–x7). Arg-only scripts resolve to .argsModified
        // (run the original with edited regs), NOT .returnReplaced (which would
        // skip the original entirely) — unless a return-style output is also set.
        var edits: [String: String] = [:]
        for i in 0...7 {
            if let s = out.objectForKeyedSubscript("x\(i)")?.toString(),
               !s.isEmpty, s != "undefined" { edits["x\(i)"] = s }
        }
        if !edits.isEmpty {
            d.cannedArgs = edits; changed = true
            if d.replacementBody == nil, d.replacementStatus == nil, d.cannedReturnValue == nil {
                d.disposition = .argsModified
            }
        }
        // Persist script state (P1): stringify, cap keys + value length, keep-first.
        // Runs under jsLock; the whole map resets on config reload (fresh interceptor).
        if let dict = out.objectForKeyedSubscript("state")?.toDictionary() as? [String: Any] {
            var kept: [String: String] = [:]
            for k in dict.keys.sorted() {
                guard kept.count < Self.maxStateKeys else { break }
                kept[k] = String(describing: dict[k] ?? "").prefix(Self.maxStateValueChars).description
            }
            ruleState[rule.id] = kept
        }
        return changed ? d : decision(.observed, rule)
    }
}

/// Minimal shell-style glob matcher supporting `*` and `?`. Anchored full-string match.
///
/// Guest-only copy: `OPConfig.swift` keeps a local duplicate (`OPImageScope`)
/// because that file also compiles into the host app target (only
/// `OPConfig` + `OPEvent` are shared) — do not "deduplicate" across the
/// boundary.
///
/// - Parameter pattern: Shell-style pattern (`*` any run, `?` one char), case-insensitive.
/// - Parameter text: Value to test.
/// - Returns: True on anchored full-string match; false on invalid regex.
public enum OPGlob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        // Translate to NSRegularExpression for a robust full-string match.
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx += ".*"
            case "?": rx += "."
            default: rx += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        rx += "$"
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
