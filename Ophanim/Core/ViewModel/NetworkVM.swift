//
//  NetworkVM.swift
//  Ophanim
//
//  Network reachability view model.
//  Created by Isaac Marovitz on 09/10/2022.
//

import SystemConfiguration
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
        // NOTE: SCNetworkReachability is deprecated since macOS 14.4 and the
        // intended replacement is NWPathMonitor (Network framework) — but the
        // Xcode 26.6 toolchain's MacOSX26.5 SDK ships a broken Network.h
        // (includes missing 'Network/nw_object.h'), so any `import Network` in
        // this target fatals the build during clang module scanning (proven:
        // CI failure on 6ef3a4e). Revisit when the toolchain heals.
        guard let flags = getFlags() else { return false }
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let result = (isReachable && !needsConnection)

        if !result && !ToastVM.shared.toasts.contains(where: { $0.toastType == .network }) {
            ToastVM.shared.showToast(
                toastType: .network,
                toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
            )
        }

        return result
    }

    static func getFlags() -> SCNetworkReachabilityFlags? {
        guard let reachability = ipv4Reachability() ?? ipv6Reachability() else { return nil }
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {
            return nil
        }
        return flags
    }

    static func ipv4Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }

    static func ipv6Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in6()
        zeroAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin6_family = sa_family_t(AF_INET6)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
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
