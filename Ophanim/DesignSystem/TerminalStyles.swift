//
//  TerminalStyles.swift
//  Ophanim
//

import SwiftUI
import Foundation

// MARK: - Control styles

/// Terminal-style button: green outline, monospace, fills on hover/press.
struct TerminalButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((configuration.isPressed || hovering) ? Theme.accent.opacity(0.18) : Theme.surfaceRaised)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
            .foregroundColor(Theme.accent)
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Green-on-slate monospace text field with a thin border.
struct TerminalTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundColor(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
    }
}

/// Bordered "card" group box with a green title and slate fill.
struct TerminalGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(Theme.heading)
                .foregroundColor(Theme.accentBright)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }
}
