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
}
