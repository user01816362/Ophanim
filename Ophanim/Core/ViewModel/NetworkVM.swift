//
//  NetworkVM.swift
//  Ophanim
//
//  Network reachability view model.
//  Created by Isaac Marovitz on 09/10/2022.
//

import Network
import Foundation

/// First-path box: NWPathMonitor delivers the current path immediately on
/// start, so a one-shot monitor plus a bounded wait preserves the old
/// synchronous call shape without hanging. Lock-guarded: the update handler
/// runs on the monitor queue (concurrently-executing from the checker's view).
private final class FirstPathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private let semaphore = DispatchSemaphore(value: 0)

    func set(_ satisfied: Bool) {
        let first = lock.withLock { () -> Bool in
            guard value == nil else { return false }
            value = satisfied
            return true
        }
        if first { semaphore.signal() }
    }

    func wait(timeout: DispatchTime) -> Bool {
        _ = semaphore.wait(timeout: timeout)
        return lock.withLock { value } ?? false
    }
}

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
        // One-shot NWPathMonitor (Network framework — the SCNetworkReachability
        // family is deprecated since macOS 14.4). The first update carries the
        // current path; the bounded wait keeps this synchronous and hang-free.
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ophanim.reachability")
        let box = FirstPathBox()
        monitor.pathUpdateHandler = { path in box.set(path.status == .satisfied) }
        monitor.start(queue: queue)
        let result = box.wait(timeout: .now() + 2)
        monitor.cancel()

        if !result && !ToastVM.shared.toasts.contains(where: { $0.toastType == .network }) {
            ToastVM.shared.showToast(
                toastType: .network,
                toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
            )
        }

        return result
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
