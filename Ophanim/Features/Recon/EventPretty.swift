//  EventPretty.swift
//  Ophanim
//
//  Body render chain for the log viewer (ported): Content-Type dispatch with graceful
//  degradation (plist/form/multipart/image/inflate), sniffing when the header lies or
//  is absent. Decoding happens here at render, never in the log.

import Foundation
import Compression

extension LogViewerView {
    private static func looksLikePlist(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(200))
        if head.starts(with: [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) { return true } // bplist
        guard let text = String(bytes: head, encoding: .utf8) else { return false }
        return text.contains("plist")
    }

    /// Decode a binary or XML plist for display. JSON-bridgeable roots pretty-print;
    /// anything else renders as a plist description. Unparseable data returns nil so the
    /// chain keeps degrading instead of showing a wrong decode.
    private static func prettyPlist(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        if JSONSerialization.isValidJSONObject(plist),
           let out = try? JSONSerialization.data(withJSONObject: plist,
                                                 options: [.prettyPrinted, .withoutEscapingSlashes]),
           let s = String(data: out, encoding: .utf8) {
            return s
        }
        return String(describing: plist)
    }

    /// One row per form field, values capped: form bodies carry the same secrets as
    /// headers (the sink masks redacted keys before this ever renders).
    private static func prettyForm(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return data.base64EncodedString()
        }
        let rows = text.split(separator: "&").prefix(50).map { part -> String in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return String(part).removingPercentEncoding ?? String(part) }
            let value = (kv[1].removingPercentEncoding ?? kv[1]).prefix(200)
            return "\(kv[0].removingPercentEncoding ?? kv[0]) = \(value)"
        }
        return rows.joined(separator: "\n")
    }

    /// Part inventory, not part bodies: names, types, sizes. Bodies stay behind the row
    /// they belong to (text parts inline when small); the log keeps canonical bytes.
    private static func prettyMultipart(_ data: Data, contentType: String) -> String? {
        guard let boundary = Self.multipartBoundary(contentType: contentType),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "--" + boundary).dropFirst()
        var rows: [String] = []
        for part in parts.prefix(20) {
            guard let sep = part.range(of: "\r\n\r\n") else { continue }
            let headers = String(part[..<sep.lowerBound])
            let body = String(part[sep.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            var name = "?"
            var type = "?"
            for line in headers.components(separatedBy: "\r\n") {
                let l = line.lowercased()
                if l.hasPrefix("content-disposition:"),
                   let r = line.range(of: "name=\"") {
                    name = String(line[r.upperBound...].prefix(while: { $0 != "\"" }))
                }
                if l.hasPrefix("content-type:") {
                    type = line.split(separator: ":").dropFirst().joined(separator: ":")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            if body.count <= 300 && (type == "?" || type.hasPrefix("text")) {
                rows.append("part \"\(name)\" (\(type), \(body.utf8.count) bytes): \(body)")
            } else {
                rows.append("part \"\(name)\" (\(type), \(body.utf8.count) bytes)")
            }
        }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    private static func multipartBoundary(contentType: String) -> String? {
        for param in contentType.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if kv.count == 2, kv[0].lowercased() == "boundary" {
                let b = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return b.isEmpty ? nil : b
            }
        }
        return nil
    }

    /// Dimension sniff without decoding: IHDR/SOFn/GIF headers only, no image pipeline.
    /// Anything else returns nil and the chain falls through to text/base64.
    private static func imageDimensions(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(64))
        // PNG: 8-byte magic, IHDR at 12, width/height big-endian at 16/20.
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) && b.count >= 24 {
            let w = UInt32(b[16]) << 24 | UInt32(b[17]) << 16 | UInt32(b[18]) << 8 | UInt32(b[19])
            let h = UInt32(b[20]) << 24 | UInt32(b[21]) << 16 | UInt32(b[22]) << 8 | UInt32(b[23])
            return "PNG image \(w)×\(h)"
        }
        // JPEG: scan segments for a start-of-frame marker.
        if b.starts(with: [0xFF, 0xD8]) {
            var i = 2
            while i + 8 < b.count {
                guard b[i] == 0xFF else { break }
                let marker = b[i + 1]
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if (0xC0...0xC3).contains(marker) || (0xC5...0xC7).contains(marker)
                    || (0xC9...0xCB).contains(marker) || (0xCD...0xCF).contains(marker) {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return "JPEG image \(w)×\(h)"
                }
                if len < 2 { break }
                i += 2 + len
            }
        }
        // GIF: 6-byte magic, dimensions little-endian at 6.
        if b.starts(with: [0x47, 0x49, 0x46]) && b.count >= 10 {
            let w = Int(b[6]) | Int(b[7]) << 8
            let h = Int(b[8]) | Int(b[9]) << 8
            return "GIF image \(w)×\(h)"
        }
        return nil
    }

    /// Inflate gzip (with header) or zlib-wrapped deflate. Raw-deflate fallback excluded:
    /// ambiguous framing must degrade to raw bytes, not to a wrong decode. Output capped
    /// at 1 MB (bomb safety) via the gzip isize trailer; zlib streams without a trailer
    /// are capped the same way by refusing oversized inputs.
    private static func inflate(_ data: Data) -> Data? {
        if data.starts(with: [0x1F, 0x8B]) { return gunzip(data) }
        guard data.count <= 1_048_576 else { return nil }
        return zlibInflate(data)
    }

    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[2] == 0x08 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8)
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        // isize trailer: original size mod 2^32. Bombs refuse via the cap.
        let isize = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8
            | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        guard isize > 0, isize <= 1_048_576 else { return nil }
        return zlibInflate(Data(b[i..<(b.count - 8)]), capacity: isize)
    }

    private static func zlibInflate(_ data: Data, capacity: Int = 1_048_576) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.baseAddress else { return nil }
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return compression_decode_buffer(dstBase.assumingMemoryBound(to: UInt8.self), capacity,
                                                 srcBase.assumingMemoryBound(to: UInt8.self), data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
            guard written > 0 else { return nil }
            out.count = written
            return out
        }
    }
}
