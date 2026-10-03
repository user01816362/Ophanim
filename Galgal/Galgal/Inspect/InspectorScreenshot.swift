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

    /// Captures the key window at 1x, downscales to the maxEdge cap, redacts secure frames,
    /// and JPEG-encodes. The downscale and the redaction share one pass.
    ///
    /// - Parameter redact: Black out secure-field frames before encoding.
    /// - Returns: JPEG data plus pixel size, or nil when no window is capturable.
    static func capture(redact: Bool, annotate: Bool = false, cropTo: CGRect? = nil)
    -> (data: Data, width: Int, height: Int)? {
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
        // Element crop (optional): intersect the requested window-points frame with
        // the capture, in downscaled pixels. Empty intersection fails nil (caller
        // reports it stated); the crop keeps full JPEG quality, no re-downscale.
        var framed: CGImage = out
        if let crop = cropTo {
            let px = CGRect(x: crop.origin.x * scale, y: crop.origin.y * scale,
                            width: crop.width * scale, height: crop.height * scale)
                .intersection(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            guard !px.isNull, px.width >= 2, px.height >= 2,
                  let cut = out.cropping(to: px.integral) else { return nil }
            framed = cut
        }
        // Optional overlay (default off): actionable-node frames + class names, drawn
        // AFTER redaction fill so boxes never leak masked text (labels are class names
        // only). Same membership rule as the host nodes[] filter, so overlay boxes and
        // tappable ids agree. Tree frames are window points; the image is window points
        // × scale — one uniform factor, no per-axis drift.
        let final: CGImage
        if annotate {
            // Boxes in output-pixel space: full capture maps window points × scale;
            // a crop additionally shifts by the crop origin. Precomputed here so the
            // overlay never re-derives geometry (and agrees with nodes[] frames).
            let origin = cropTo?.origin ?? .zero
            let boxes: [(CGRect, String)] = actionableFrames(in: window).compactMap { (frame, cls) in
                let px = CGRect(x: (frame.origin.x - origin.x) * scale,
                                y: (frame.origin.y - origin.y) * scale,
                                width: frame.width * scale,
                                height: frame.height * scale)
                let vis = px.intersection(CGRect(x: 0, y: 0,
                                                 width: framed.width, height: framed.height))
                guard !vis.isNull, vis.width >= 2, vis.height >= 2 else { return nil }
                return (vis, cls)
            }
            if let overlaid = overlay(framed, boxes: boxes) {
                final = overlaid
            } else {
                final = framed
            }
        } else {
            final = framed
        }
        // Encode straight into mutable data: Finalize writes the JPEG there, no copy-out API
        // needed (there is none - the destination owns the buffer).
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded as CFMutableData,
                                                          "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, final, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (encoded as Data, final.width, final.height)
    }

    /// Frames of actionable nodes for the annotate overlay: buttons, text inputs,
    /// and labeled views — the same membership rule as the host nodes[] filter, so
    /// every drawn box has a tappable id. Class names only, never text: safe to
    /// draw over redacted captures. Capped; touch-unknown views stay unboxed.
    private static func actionableFrames(in window: UIWindow) -> [(frame: CGRect, cls: String)] {
        var out: [(CGRect, String)] = []
        func walk(_ view: UIView) {
            if out.count >= 100 { return }
            let role = Inspector.role(of: view)
            let (text, _, _) = Inspector.classify(view)
            if role == "button" || role == "textfield" || role == "textview" ||
               !(text?.isEmpty ?? true) || view.accessibilityLabel != nil ||
               view.accessibilityIdentifier != nil {
                let f = view.convert(view.bounds, to: window)
                guard f.width >= 4, f.height >= 4 else {
                    for kid in Inspector.visibleChildren(of: view) { walk(kid) }
                    return
                }
                let short = String(describing: type(of: view)).split(separator: ".").last.map(String.init) ?? "?"
                out.append((f, short))
            }
            for kid in Inspector.visibleChildren(of: view) { walk(kid) }
        }
        for kid in Inspector.visibleChildren(of: window) { walk(kid) }
        return out
    }

    /// Draw red frames + class labels over `image` (top-left origin, UIKit space).
    /// Boxes arrive in output pixels (caller maps window points); returns nil on
    /// renderer failure (caller falls back to the plain capture).
    private static func overlay(_ image: CGImage, boxes: [(CGRect, String)]) -> CGImage? {
        let ui = UIImage(cgImage: image)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: image.width, height: image.height))
        return renderer.image { _ in
            ui.draw(at: .zero)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.red,
                .backgroundColor: UIColor(white: 0, alpha: 0.55),
            ]
            for (rect, cls) in boxes {
                UIColor.red.setStroke()
                UIRectFrame(rect)
                (cls as NSString).draw(at: CGPoint(x: rect.minX + 2, y: max(0, rect.minY - 13)),
                                       withAttributes: attrs)
            }
        }.cgImage
    }
}
