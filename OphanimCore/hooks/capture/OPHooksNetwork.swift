//
//  OPHooksNetwork.swift
//  OphanimCore
//
//  Network capture - Layer 2/3: a custom URLProtocol that observes every HTTP(S) request/response
//  routed through the URL Loading System, plus a URLSessionConfiguration swizzle so custom sessions
//  (not just URLSession.shared) are covered. Supports interception: a matching rule can BLOCK a
//  request or REPLACE its response with a canned body/status. TLS-plaintext (boringssl) and raw
//  socket (connect/getaddrinfo) layers are added separately.
//
//  Limitations: (1) WebSocket frames don't traverse URLProtocol - captured separately below by
//  swizzling URLSessionWebSocketTask send/receive. (2) Background URLSessions run out-of-process
//  (nsurlsessiond) and ignore custom protocolClasses, so their HTTP bodies aren't capturable here.
//

import Foundation

enum OPNetworkHooks {
    /// Installs the URLProtocol + session-config + WebSocket swizzles. Gated on the .network category.
    static func install() {
        guard OPAgent.shared.isActive(.network) else { return }
        URLProtocol.registerClass(OPURLProtocol.self)          // covers URLSession.shared
        swizzleSessionConfig("defaultSessionConfiguration")    // covers .default sessions
        swizzleSessionConfig("ephemeralSessionConfiguration")  // covers .ephemeral sessions
        installWebSocketHooks()                                // covers URLSessionWebSocketTask
    }

    // MARK: - WebSocket capture (URLProtocol doesn't see WS frames)

    private static func installWebSocketHooks() {
        // send/receive are implemented on the concrete __NSURLSessionWebSocketTask subclass; the
        // public NSURLSessionWebSocketTask is abstract. Prefer the concrete class.
        guard let cls = NSClassFromString("__NSURLSessionWebSocketTask")
                     ?? NSClassFromString("NSURLSessionWebSocketTask") else { return }
        swizzleWSSend(cls)
        swizzleWSReceive(cls)
    }

    private static func swizzleWSSend(_ cls: AnyClass) {
        let sel = NSSelectorFromString("sendMessage:completionHandler:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { task, msg, handler in
            emitWS(task: task, msg: msg, dir: "send")
            orig(task, sel, msg, handler)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func swizzleWSReceive(_ cls: AnyClass) {
        let sel = NSSelectorFromString("receiveMessageWithCompletionHandler:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { task, handler in
            // Wrap the completion so we log the received message, then forward to the app.
            let wrapped: @convention(block) (AnyObject?, AnyObject?) -> Void = { message, error in
                emitWS(task: task, msg: message, dir: "receive")
                if let handler = handler {
                    let call = unsafeBitCast(handler, to: (@convention(block) (AnyObject?, AnyObject?) -> Void).self)
                    call(message, error)
                }
            }
            orig(task, sel, wrapped as AnyObject)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func emitWS(task: AnyObject, msg: AnyObject?, dir: String) {
        guard OPAgent.shared.isActive(.network) else { return }
        var host: String?
        // KVC without responds(to:) throws NSUnknownKeyException straight
        // into the app (Swift cannot catch ObjC exceptions) — probe first,
        // fail open with metadata only.
        if task.responds(to: NSSelectorFromString("currentRequest")),
           let req = task.value(forKey: "currentRequest") as? URLRequest { host = req.url?.host }
        var str: String?
        var data: Data?
        if let msg = msg, msg.responds(to: NSSelectorFromString("string")) {
            str = msg.value(forKey: "string") as? String
        }
        if let msg = msg, msg.responds(to: NSSelectorFromString("data")) {
            data = (msg.value(forKey: "data") as? Data) ?? str?.data(using: .utf8)
        } else {
            data = str?.data(using: .utf8)
        }
        let ctx = OPCallContext(category: .network, layer: .objc,
                                api: "URLSessionWebSocketTask.\(dir)",
                                fields: ["transport": "websocket"], host: host)
        if dir == "send" { ctx.requestBody = data } else { ctx.responseBody = data }
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "WebSocket \(dir) \(data?.count ?? 0) bytes"))
    }

    /// Swizzles a URLSessionConfiguration class getter to prepend our protocol to protocolClasses.
    ///
    /// - Parameter name: Configuration getter selector name (default/ephemeral).
    private static func swizzleSessionConfig(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getClassMethod(URLSessionConfiguration.self, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { obj in
            let cfg = orig(obj, sel)
            var protos = cfg.protocolClasses ?? []
            if !protos.contains(where: { $0 === OPURLProtocol.self }) {
                protos.insert(OPURLProtocol.self, at: 0)
                cfg.protocolClasses = protos
            }
            return cfg
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

final class OPURLProtocol: URLProtocol, URLSessionDataDelegate {
    private static let handledKey = "be.ophanim.handled"
    private var session: URLSession?
    private var proxyTask: URLSessionDataTask?
    private var responseData = Data()
    private var overflowBytes = 0
    private var httpResponse: HTTPURLResponse?
    private var ctx: OPCallContext?
    private var decision: OPDecision = .observe

    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Starts intercepting a request: consults policy (block/replace/passthrough) and proxies it.
    /// Caller attribution is captured here at load start, never at completion (which runs on the
    /// session delegate queue and would attribute the loader instead of the originator).
    override func startLoading() {
        let req = request
        var fields: [String: String] = ["method": req.httpMethod ?? "GET"]
        if let h = req.allHTTPHeaderFields { for (k, v) in h { fields["req.\(k)"] = v } }
        // Caller attribution (opt-in, default off) happens HERE at load start, never at
        // completion: didComplete runs on the session delegate queue, whose stack attributes
        // the loader. startLoading is the closest observable point to the originator.
        if OPAgent.shared.config.captureNetworkCallers {
            let callers = OPCallerAttribution.attribute()
            fields["callerThread"] = callers.thread
            if !callers.classes.isEmpty {
                fields["callerClasses"] = callers.classes.joined(separator: ",")
            }
            if !callers.symbols.isEmpty {
                fields["callerSymbols"] = callers.symbols.joined(separator: ",")
            }
        }
        let ctx = OPCallContext(category: .network, layer: .urlProtocol, api: "URLSession.request",
                                fields: fields, host: req.url?.host, url: req.url?.absoluteString,
                                requestBody: req.httpBody)
        self.ctx = ctx
        let decision = OPAgent.shared.intercept(ctx)
        self.decision = decision

        switch decision.disposition {
        case .blocked:
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision, summary: "blocked"))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case .returnReplaced where decision.replacementBody != nil:
            let body = decision.replacementBody ?? Data()
            let status = decision.replacementStatus ?? 200
            let headers = decision.replacementHeaders ?? ["Content-Type": "application/octet-stream"]
            ctx.responseBody = body
            if let url = req.url,
               let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: headers) {
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "canned \(status)"))
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            fallthrough
        default:
            // Pass through: re-issue the request with a marker so we don't re-enter.
            // A request that cannot be copied fails STATED (didFail) — never a
            // silent hang: the loader would wait forever otherwise.
            guard let mutable = (req as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
                return
            }
            URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
            // Drop the app's explicit Accept-Encoding so URLSession manages compression itself and
            // hands us DECOMPRESSED bytes - otherwise we'd capture (and log) raw gzip/brotli, which
            // looks like encrypted garbage. URLSession still negotiates gzip transparently.
            mutable.setValue(nil, forHTTPHeaderField: "Accept-Encoding")
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            proxyTask = session?.dataTask(with: mutable as URLRequest)
            proxyTask?.resume()
        }
    }

    /// Cancels the proxied task and tears down the private session.
    override func stopLoading() {
        proxyTask?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpResponse = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Bounded accumulator (jetsam guard): stop buffering past the body
        // cap, keep counting the dropped tail. The cap still applies at
        // event build; overflow is reported, never silently lost.
        let cap = OPAgent.shared.bodyCap
        let room = max(0, cap - responseData.count)
        if room > 0 { responseData.append(data.prefix(room)) }
        overflowBytes += max(0, data.count - room)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let ctx = ctx {
            ctx.responseBody = responseData
            if overflowBytes > 0 {
                ctx.fields["truncatedBytes"] = String(overflowBytes)
            }
            if let r = httpResponse {
                ctx.fields["status"] = String(r.statusCode)
                for (k, v) in r.allHeaderFields { ctx.fields["resp.\(k)"] = "\(v)" }
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                summary: error == nil ? "ok" : "error: \(error!.localizedDescription)"))
        }
        if let error = error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        self.session?.finishTasksAndInvalidate()
    }
}
