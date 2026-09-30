//
//  Theme.swift
//  Ophanim
//
//  Central "hackery" theme: dark slate surfaces with phosphor-green accents, system monospace
//  everywhere, plus optional theatrics (digital rain, scanlines, glow) gated behind a single
//  app-wide toggle (`ophanim.fx.enabled`). Apply `.ophanimTheme()` at a window/scene root.
//

import SwiftUI
import Foundation   // sin() for the wind / sweep animations


// MARK: - Palette

enum Theme {
    // Surfaces - near-black slate, slightly green-shifted.
    static let bg            = Color(hex: 0x0A0E0B)
    static let surface       = Color(hex: 0x111712)
    static let surfaceRaised = Color(hex: 0x18211A)
    static let border        = Color(hex: 0x254A30)

    // Greens - primary accent / highlight / dim.
    static let accent        = Color(hex: 0x3CE07A)   // primary green
    static let accentBright  = Color(hex: 0x7CFFB0)   // headings / glow
    static let accentDim     = Color(hex: 0x2B8F52)

    // Purples - secondary accent (selection, active/intercept states, alternating headings).
    static let purple        = Color(hex: 0xB36CFF)
    static let purpleBright  = Color(hex: 0xD7B0FF)
    static let purpleDim     = Color(hex: 0x7E4FB8)

    // Text.
    static let textPrimary   = Color(hex: 0xCBF5D6)   // soft green-white
    static let textSecondary = Color(hex: 0x6FA982)   // dim green-gray
    static let danger        = Color(hex: 0xFF5C5C)

    // Fonts - system monospaced at semantic-ish sizes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let title   = mono(18, .bold)
    static let heading = mono(13, .semibold)
    static let body    = mono(12, .regular)
    static let caption = mono(10, .regular)
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
