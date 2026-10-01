import Foundation

/// Shared timeouts/budgets for MCP operations. One place so tools agree.
enum MCPTimeouts {
    /// launch_app semaphore bound.
    static let launch: TimeInterval = 120
    /// install_app importer bound.
    static let install: TimeInterval = 600
    /// Injection-strategy load-command settle loop.
    static let installSettle: TimeInterval = 15
    /// Rate-limit rolling window.
    static let rateWindow: TimeInterval = 60
}
