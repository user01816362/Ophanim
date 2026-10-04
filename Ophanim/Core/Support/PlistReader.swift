//
//  PlistReader.swift
//  Ophanim
//
//  Single owner for Info.plist dictionary reads.
//

import Foundation

/// Single owner for Info.plist dictionary reads (see D6 audit).
/// All call sites that previously inlined the Data+propertyList chain
/// must use this helper so the decode stays in one place.
enum PlistReader {
    /// Reads a plist file as a dictionary. Never throws: missing/corrupt files
    /// read as empty.
    ///
    /// - Parameter plistURL: The plist file URL.
    /// - Returns: The dictionary, or empty when unreadable.
    static func appInfoDict(at plistURL: URL) -> [String: Any] {
        (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    }

    /// Reads any plist file as a dictionary, distinguishing unreadable (nil) from
    /// empty. For MCP container reads/edits that must fail stated on missing files
    /// instead of silently operating on empty.
    ///
    /// - Parameter plistURL: The plist file URL.
    /// - Returns: The dictionary, or nil when missing/corrupt/non-dict.
    static func plistDict(at plistURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return plistDict(data: data)
    }

    /// Decodes plist bytes (R10-sanctioned owner for `propertyList`: callers
    /// with in-memory plist XML — e.g. `codesign --entitlements :-` output —
    /// route through here instead of decoding inline).
    ///
    /// - Parameter data: The plist bytes.
    /// - Returns: The dictionary, or nil when corrupt/non-dict.
    static func plistDict(data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Writes a dictionary as an XML plist, atomically.
    ///
    /// - Parameters:
    ///   - dict: The dictionary to write.
    ///   - url: Destination file URL.
    /// - Throws: Encode/write failures.
    static func writePlistDict(_ dict: [String: Any], to url: URL) throws {
        let out = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try out.write(to: url, options: .atomic)
    }
}
