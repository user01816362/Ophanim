//
//  URLHandler.swift
//  Ophanim
//
//  Custom URL-scheme dispatch (install/open actions).
//  Created by Venti on 14/02/2023.
//

import Foundation

enum URLTypes: Int, Equatable {
    case keymap
    case app
}

enum URLAction: Int, Equatable {
    case add
    case remove
    case update
    case install
    case open
}

@Observable class URLObservable {
    var url: String?
    var type: URLTypes?
    var action: URLAction?

    public nonisolated(unsafe) static let shared = URLObservable()
}

struct URLHandler {
    public nonisolated(unsafe) static let shared = URLHandler()

    func processURL(url: URL) {
        guard let urlComponenents = NSURLComponents(url: url, resolvingAgainstBaseURL: false),
              let uriHost = urlComponenents.host,
              let params = urlComponenents.queryItems else {
                // Fall back to old url handler (for files)
                if url.pathExtension == "ipa" {
                    AppInstalls.installIPA(at: url)
                }
                return
            }
        // URI format: ophanimapp://<object>?action=<action>&<param>=<value>
        // No custom URI objects are handled at present; non-ipa URLs are logged and ignored.
        _ = params
        NSLog("Unknown URL: \(url)")
    }
}
