//
//  NetworkVM.swift
//  Ophanim
//
//  Network reachability view model.
//  Created by Isaac Marovitz on 09/10/2022.
//

import Foundation

/// URL-probe box: carries the data-task result and the (non-Sendable)
/// completion across the @Sendable task boundary under one lock.
private final class URLProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    private var finalURL: URL?
    private let completion: ((URL?, Bool) -> Void)?

    init(completion: ((URL?, Bool) -> Void)?) { self.completion = completion }

    func set(available: Bool, url: URL?) {
        lock.withLock {
            self.available = available
            self.finalURL = url
        }
    }

    func finish() {
        let (url, ok, cb) = lock.withLock { (finalURL, available, completion) }
        cb?(url, ok)
    }

    func snapshot() -> (URL?, Bool) {
        lock.withLock { (finalURL, available) }
    }
}

class NetworkVM {
    static func isConnectedToNetwork() -> Bool {
        // POSIX interface check (getifaddrs — stable, not deprecated, no
        // framework import): a live, non-loopback IPv4/IPv6 interface means we
        // can attempt downloads. This replaces SCNetworkReachability
        // (deprecated macOS 14.4); NWPathMonitor is the intended successor but
        // the Xcode 26.6 SDK's Network.h is broken (missing nw_object.h), so
        // `import Network` fatals this target's build (proven CI failure).
        // Revisit when the toolchain heals.
        let result = hasLiveNonLoopbackInterface()

        if !result && !ToastVM.shared.toasts.contains(where: { $0.toastType == .network }) {
            ToastVM.shared.showToast(
                toastType: .network,
                toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
            )
        }

        return result
    }

    /// True when an interface is up, running, non-loopback, and carries an
    /// IPv4 or IPv6 address (loopback alone does not count as connectivity).
    private static func hasLiveNonLoopbackInterface() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = current.pointee.ifa_flags
            let upAndRunning = (flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING)
            let loopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if upAndRunning && !loopback, let addr = current.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                    return true
                }
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }

    static func urlAccessible(url: URL,
                              popup: Bool = false,
                              completion: ((URL?, Bool) -> Void)? = nil) -> (URL?, Bool) {
        guard isConnectedToNetwork() else {
            completion?(nil, false)
            return (nil, false)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let validStatusCodes = [200, 301, 302, 303, 307, 308]

        let box = URLProbeBox(completion: completion)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let error = error {
                if popup {
                    Log.shared.error(error)
                } else {
                    Log.shared.log(error.localizedDescription, isError: true)
                }
            } else {
                if let httpResponse = response as? HTTPURLResponse {
                    if validStatusCodes.contains(httpResponse.statusCode) {
                        box.set(available: true, url: httpResponse.url)
                    } else if popup {
                        Log.shared.error("Unable to download: \(httpResponse.statusCode) " +
                                         "\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
                    }
                }
            }

            box.finish()
        }.resume()

        if completion == nil {
            semaphore.wait()
        }

        return box.snapshot()
    }
}
