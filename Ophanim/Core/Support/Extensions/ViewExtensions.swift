//
//  ViewExtensions.swift
//  Ophanim
//

import SwiftUI

extension View {
    func toastOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        return self.safeAreaBar(edge: .bottom, content: content)
    }

    func toastBackground() -> some View {
        let view = self
            .padding()
            .frame(maxWidth: .infinity)

        // Liquid-glass toast surface (floor is macOS 26, always available).
        return view.glassEffect(.regular, in: .containerRelative)
            .padding(ToastView.toastGlassPadding)
            .padding(.top)
    }

    /// Galgal-presence gating, shared by every settings pane. `hasGalgal` is nil while
    /// the check runs (treated as present: controls stay enabled, no warning flashes).
    func disabledWhenNoGalgal(_ hasGalgal: Bool?) -> some View {
        self.disabled(!(hasGalgal ?? true))
    }
}

/// The missing-Galgal warning banner (triangle + localized text), shared instead of
/// re-typed per pane. Renders nothing while the check runs or when present.
struct NoGalgalBanner: View {
    let hasGalgal: Bool?

    var body: some View {
        if !(hasGalgal ?? true) {
            HStack {
                Text("\(Image(systemName: "exclamationmark.triangle")) \(NSLocalizedString("settings.noGalgal", comment: ""))")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
        }
    }
}
