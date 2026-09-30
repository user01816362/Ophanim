import SwiftUI

/// Long-running per-app task that blocks its toggle with a spinner.
enum BlockingTask {
    case none, galgal, introspection, iosFrameworks, applicationCategoryType
}

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
    static func async(_ task: Binding<BlockingTask>, role: BlockingTask) -> AsyncToggleStyle {
        AsyncToggleStyle(task: task, role: role)
    }
}
