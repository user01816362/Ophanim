import Foundation

/// Run UI work on the main thread, synchronously. Direct when already main (zero
/// behavior change on the GUI path); `DispatchQueue.main.sync` otherwise (correct
/// blocking semantics for modals invoked off-main). For fire-and-forget UI from
/// nonisolated contexts prefer `Task { @MainActor in }`; use this only when the
/// caller needs the return value (modal answers, window handles).
enum MainDispatch {
    @discardableResult
    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}
