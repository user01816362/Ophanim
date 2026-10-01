import Foundation

/// The single observe-only emit skeleton shared by the six OP*Bridge loggers
/// (crypto/fs/keychain/process/socket/tls): re-entrancy guard, category gate,
/// intercept, observe. Bridges build their own OPCallContext (fields differ per
/// bridge) and hand it here with a summary - none of them consumes the decision
/// afterwards, so nothing is returned.
///
/// `build` runs INSIDE the guard: context construction allocates (Swift
/// Strings, dictionaries), and on hot paths (notably malloc→stat→open) that
/// allocation must happen only after the re-entrancy guard is set.
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
