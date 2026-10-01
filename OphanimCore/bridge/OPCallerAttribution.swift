//
//  OPCallerAttribution.swift
//  OphanimCore
//
//  Who sent this request? Return addresses off the current thread, symbolicated in-process
//  via dladdr, parsed to ObjC class names. In-process is load-bearing, not incidental:
//  guest addresses under ASLR are meaningless to the host, so read-time symbolication
//  anywhere else would resolve garbage. Runs only when OPConfig.captureNetworkCallers is
//  on (default off): dladdr takes the dyld lock per frame, unsuitable for hot paths at
//  full depth, so capture is 8 frames and fields carry strings, never addresses.
//

import Foundation

/// Attributed caller material for one network event. All strings, all bounded.
struct OPCallerAttribution {
    var thread: String
    var classes: [String]
    var symbols: [String]

    static let maxFrames = 32
    static let maxAppFrames = 4

    /// Capture + symbolicate the current thread. Walks up to maxFrames deep (originator
    /// frames sit below loader machinery) but keeps only app-image frames: anything under
    /// /usr/ or /System/ is loader/system, not the app. Skip the first frames (this
    /// function and the event machinery above it - same 2-frame skip as the backtrace path).
    static func attribute() -> OPCallerAttribution {
        let thread = Thread.isMainThread ? "main"
            : Thread.current.name.map { "queue:\($0)" } ?? "queue:unnamed"
        var classes: [String] = []
        var symbols: [String] = []
        for addr in Thread.callStackReturnAddresses.dropFirst(2).prefix(maxFrames) {
            let raw = addr.uint64Value
            var info = Dl_info(dli_fname: nil, dli_fbase: nil, dli_sname: nil, dli_saddr: nil)
            guard dladdr(UnsafeRawPointer(bitPattern: UInt(raw)), &info) != 0,
                  let sname = info.dli_sname.map({ String(cString: $0) }) else { continue }
            let image = info.dli_fname.map({ String(cString: $0) }) ?? ""
            guard !image.hasPrefix("/usr/") && !image.hasPrefix("/System/") else { continue }
            if symbols.count >= maxAppFrames { break }
            symbols.append(shortSymbol(sname))
            if let cls = objcClass(from: sname), !classes.contains(cls) {
                classes.append(cls)
            }
        }
        return OPCallerAttribution(thread: thread, classes: classes, symbols: symbols)
    }

    /// "-[T1StatusCell layoutSubviews]" -> "T1StatusCell". Swift-mangled ($s/$S/_T) and C
    /// symbols have no class to parse - they ride along raw in `symbols` instead.
    static func objcClass(from symbol: String) -> String? {
        guard symbol.hasPrefix("-[") || symbol.hasPrefix("+[") else { return nil }
        let inner = symbol.dropFirst(2)
        guard let space = inner.firstIndex(of: " ") else { return nil }
        let cls = String(inner[..<space])
        return cls.isEmpty ? nil : cls
    }

    /// Trim the noise dladdr prepends: leading underscores on C symbols are an ABI prefix,
    /// not part of the name. ObjC "-[...]"/"+[...]" forms pass through untouched.
    static func shortSymbol(_ symbol: String) -> String {
        symbol.hasPrefix("_") && !symbol.hasPrefix("_T") ? String(symbol.dropFirst()) : symbol
    }
}
