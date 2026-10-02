//
//  Controls.swift
//  Ophanim
//
//  Shared blocking-task toggle style. Long per-app tasks (Galgal install,
//  introspection / framework injection) swap their toggle for a spinner via
//  BlockingTask so a second flip cannot overlap the run.
//

import SwiftUI

/// Long-running per-app task that blocks its toggle with a spinner.
enum BlockingTask {
    case none, galgal, introspection, iosFrameworks, applicationCategoryType
}

/// Toggle that swaps itself for a spinner while its `role` task runs, so a second
/// flip cannot overlap the in-flight operation.
struct AsyncToggleStyle: ToggleStyle {
    @Binding var task: BlockingTask

    var role: BlockingTask

    func makeBody(configuration: Configuration) -> some View {
        if task == role {
            return AnyView(
                HStack(spacing: 3) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)

                    configuration.label
                }
            )
        } else {
            return AnyView(
                Toggle(isOn: configuration.$isOn) { configuration.label }
            )
        }
    }
}

extension ToggleStyle where Self == AsyncToggleStyle {
    /// Binds a toggle to one `role` of the owner's shared task state.
    ///
    /// - Parameter task: Shared task state; the toggle spins while it equals `role`.
    /// - Parameter role: This toggle's task.
    /// - Returns: The blocking toggle style.
    static func async(_ task: Binding<BlockingTask>, role: BlockingTask) -> AsyncToggleStyle {
        AsyncToggleStyle(task: task, role: role)
    }
}
