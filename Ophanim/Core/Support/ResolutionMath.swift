//
//  ResolutionMath.swift
//  Ophanim
//
//  Pure resolution/aspect math for the graphics pane.
//

import Foundation

/// Pure resolution/aspect math for the graphics pane. Value-in/value-out;
/// the pane writes results back to settings. Unit-testable without AppKit.
enum ResolutionMath {
    static func widthFromAspectRatio(height: Int, aspectRatio: Int) -> Int {
        let wr: Int; let hr: Int
        switch aspectRatio {
        case 0: wr = 4; hr = 3
        case 1: wr = 16; hr = 9
        case 2: wr = 16; hr = 10
        default: wr = 16; hr = 9
        }
        return (height / hr) * wr
    }

    static func heightForNotch(width: Int, height: Int, hasNotch: Bool) -> Int {
        let w = Float(width); let h = Float(height)
        if hasNotch && (h / w) * 16.0 > 10.3 && (h / w) * 16.0 < 10.4 {
            return Int((w / 16) * 10)
        }
        return height
    }

    /// Returns (width, height, warn) where warn is true past the pixel budget
    /// that tends to crash hosted apps.
    static func resolution(mode: Int, aspectRatio: Int, customWidth: Int, customHeight: Int,
                           customScaler: Double, screenWidth: Int, screenHeight: Int,
                           hasNotch: Bool) -> (width: Int, height: Int, warn: Bool) {
        let w: Int; let h: Int
        switch mode {
        case 1:
            w = screenWidth
            h = heightForNotch(width: screenWidth, height: screenHeight, hasNotch: hasNotch)
        case 2:
            h = 1080; w = widthFromAspectRatio(height: h, aspectRatio: aspectRatio)
        case 3:
            h = 1440; w = widthFromAspectRatio(height: h, aspectRatio: aspectRatio)
        case 4:
            h = 2160; w = widthFromAspectRatio(height: h, aspectRatio: aspectRatio)
        case 5:
            w = customWidth; h = customHeight
        default:
            h = 1080; w = 1920
        }
        return (w, h, Double(w * h) * customScaler >= 2621440 * 2.0)
    }

    static func resizableRatio(type: Int, customWidth: Int, customHeight: Int) -> (Int, Int) {
        switch type {
        case 0: return (0, 0)
        case 1: return (customWidth, customHeight)
        case 2: return (4, 3)
        case 3: return (16, 9)
        case 4: return (16, 10)
        default: return (16, 9)
        }
    }
}
