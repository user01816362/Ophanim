//
//  NetworkVM.swift
//  Ophanim
//
//  Created by Isaac Marovitz on 09/10/2022.
//

import Network
import Foundation

class NetworkVM {
    static func isConnectedToNetwork() -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "io.ophanim.reachability")
        var reachable = false
        let sema = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            reachable = path.status == .satisfied
            sema.signal()
            monitor.cancel()
        }
        monitor.start(queue: queue)
        _ = sema.wait(timeout: .now() + 5)
        monitor.cancel()

        let result = reachable

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

        var available = false
        var finalURL: URL?

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
                        finalURL = httpResponse.url
                        available = true
                    } else if popup {
                        Log.shared.error("Unable to download: \(httpResponse.statusCode) " +
                                         "\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
                    }
                }
            }

            completion?(finalURL, available)
        }.resume()

        if completion == nil {
            semaphore.wait()
        }

        return (finalURL, available)
    }
}
