import Foundation

/// Single owner for Info.plist dictionary reads (see D6 audit).
/// All call sites that previously inlined the Data+propertyList chain
/// must use this helper so the decode stays in one place.
enum PlistReader {
    static func appInfoDict(at plistURL: URL) -> [String: Any] {
        (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    }
}
