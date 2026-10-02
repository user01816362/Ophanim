//
//  MainDispatch.swift
//  Ophanim
//
//  Main-thread sync runner for modal answers and window handles.
//

import Foundation

/// Run UI work on the main thread, synchronously. Direct when already main (zero
/// behavior change on the GUI path); `DispatchQueue.main.sync` otherwise (correct
/// blocking semantics for modals invoked off-main). For fire-and-forget UI from
/// nonisolated contexts prefer `Task { @MainActor in }`; use this only when the
/// caller needs the return value (modal answers, window handles).
enum MainDispatch {
    /// Runs work on the main thread, synchronously, returning its value.
    ///
    /// Direct when already main; `DispatchQueue.main.sync` otherwise. For
    /// fire-and-forget UI from nonisolated contexts prefer
    /// `Task { @MainActor in }`.
    ///
    /// - Parameter work: The closure to run.
    /// - Returns: The closure's value.
    @discardableResult
    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}
