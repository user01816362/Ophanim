//
//  OPObserve.swift
//  OphanimCore
//
//  Shared observe-only emit path for the ObjC-callable capture bridges. Every bridge builds
//  its own OPCallContext (fields differ per bridge) and hands it here; the guard, category
//  gate, intercept, and observe steps are identical, so they live in one place.
//

import Foundation

/// Runs one built call context through the guard, category gate, and policy engine, then emits it.
///
/// `build` runs INSIDE the guard: context construction allocates (Swift
/// Strings, dictionaries), and on hot paths (notably malloc→stat→open) that
/// allocation must happen only after the re-entrancy guard is set.
///
/// - Parameter category: Capture category gating this emit (skipped when inactive).
/// - Parameter build: Builds the context plus its one-line summary. Runs only when unguarded and active.
enum OPObserve {
    static func emit(category: OPCategory, _ build: () -> (ctx: OPCallContext, summary: String)) {
        guard !OPReentry.active else { return }
        OPReentry.guarded {
            guard OPAgent.shared.isActive(category) else { return }
            let (ctx, summary) = build()
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                        summary: summary))
        }
    }
}
