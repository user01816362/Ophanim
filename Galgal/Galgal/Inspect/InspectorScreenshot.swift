//
//  InspectorScreenshot.swift
//  Galgal
//
//  In-process screenshot of the key window. Current APIs only:
//  - UIGraphicsImageRenderer (the UIGraphicsBeginImageContext* family is deprecated).
//  - drawHierarchy(in:afterScreenUpdates:) on the window (renderInContext misses
//    live-backed layers; drawHierarchy is the documented in-process snapshot path).
//  Redaction (when on) blacks out the frames of secure fields collected by the tree walk,
//  in the same window coordinate space, before encoding - masked pixels never exist.
//

import UIKit
import ImageIO

enum InspectorScreenshot {
    /// Longest edge cap: keeps the JPEG near the ~1MB transport ceiling without a second pass.
    static let maxEdge: CGFloat = 1280

    static func capture(redact: Bool) -> (data: Data, width: Int, height: Int)? {
        guard let window = Inspector.keyWindow() else { return nil }
        let bounds = window.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(1, maxEdge / max(bounds.width, bounds.height))

        // 1x render: the pixels are downscaled to target size anyway, so rendering retina
        // density first only burns 4-9x memory to throw it away.
        var format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return nil }

        // Downscale + redact in one pass when needed; otherwise encode as-is.
        let targetW = Int(bounds.width * scale), targetH = Int(bounds.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: targetW, height: targetH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        if redact {
            // This window's secure frames only: forest-wide frames live in other windows'
            // coordinate spaces and would black out the wrong pixels here.
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for frame in Inspector.secureFrames(in: window) {
                // CoreGraphics origin is bottom-left; UIKit frames are top-left.
                let flipped = CGRect(x: frame.origin.x * scale,
                                     y: CGFloat(targetH) - (frame.origin.y + frame.height) * scale,
                                     width: frame.width * scale, height: frame.height * scale)
                ctx.fill(flipped)
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        // Encode straight into mutable data: Finalize writes the JPEG there, no copy-out API
        // needed (there is none - the destination owns the buffer).
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded as CFMutableData,
                                                          "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (encoded as Data, targetW, targetH)
    }
}
