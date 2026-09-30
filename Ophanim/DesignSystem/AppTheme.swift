//
//  AppTheme.swift
//  Ophanim
//

import SwiftUI
import Foundation

// MARK: - Theme application

/// Root modifier: dark scheme, green tint, monospace everywhere, slate background, and (when the
/// fx toggle is on) a faint scanline overlay. Apply once per window/scene root.
struct OphanimThemeModifier: ViewModifier {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true

    @AppStorage("ophanim.rain.enabled") private var rainEnabled = false
    @AppStorage("ophanim.fx.eyes") private var eyesEnabled = true

    func body(content: Content) -> some View {
        content
            .monospacedEverywhere()
            .tint(Theme.accent)
            .foregroundColor(Theme.textPrimary)
            .background {
                // Slate base + (when fx is on) faint background effects behind ALL content, so every
                // themed window - editors, the options/settings sheets, the log viewer - shares them,
                // not just the library. Content sits on top; effects show through margins and
                // transparent areas.
                ZStack {
                    Theme.bg
                    if fxEnabled && rainEnabled {
                        DigitalRainView().opacity(0.16).allowsHitTesting(false)
                    }
                    if fxEnabled && eyesEnabled {
                        EyeballsView().opacity(0.78).allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
            }
            .overlay {
                if fxEnabled {
                    ScanlineOverlay().allowsHitTesting(false).ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
    }
}

private struct MonospaceEverywhere: ViewModifier {
    func body(content: Content) -> some View {
        content.fontDesign(.monospaced)
    }
}

extension View {
    func ophanimTheme() -> some View { modifier(OphanimThemeModifier()) }
    func monospacedEverywhere() -> some View { modifier(MonospaceEverywhere()) }

    /// Phosphor glow for headings/accents - no-op when effects are disabled.
    func phosphorGlow(_ color: Color = Theme.accent, radius: CGFloat = 4) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }
}

private struct GlowModifier: ViewModifier {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true
    let color: Color
    let radius: CGFloat
    func body(content: Content) -> some View {
        if fxEnabled {
            content.shadow(color: color.opacity(0.7), radius: radius)
        } else {
            content
        }
    }
}
