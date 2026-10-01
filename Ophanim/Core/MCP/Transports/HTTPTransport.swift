import Foundation
import Darwin

/// The default local MCP endpoint port.
let kMCPPort: UInt16 = 20033

/// The configured MCP HTTP port (UserDefaults `ophanim.mcp.port`), falling back to kMCPPort when
/// unset or out of the valid range.
var mcpConfiguredPort: UInt16 {
    let v = UserDefaults.standard.integer(forKey: "ophanim.mcp.port")
    return (1024...65535).contains(v) ? UInt16(v) : kMCPPort
}

/// The configured bind address as a string: "loopback" (default, 127.0.0.1), "all" (0.0.0.0 - all
/// interfaces), or a specific IPv4 address. UserDefaults `ophanim.mcp.bind` holds the mode; when it
/// is "specific" the address is read from `ophanim.mcp.bindIP`.
///
/// The configured MCP HTTP token (UserDefaults `ophanim.mcp.token`). Empty = none
/// configured. Required for write tools on non-loopback binds (see requiredToken);
/// loopback stays open (same-machine trust boundary, current behavior).
var mcpConfiguredToken: String {
    UserDefaults.standard.string(forKey: "ophanim.mcp.token") ?? ""
}

/// Token required for this request, if any. Loopback never requires one; a
/// non-loopback bind fails closed (mint-and-print on first use, persisted).
/// Reads stay open everywhere; only tools/call names outside the read-only sets pay.
func mcpRequiredToken(bindMode: String) -> String? {
    if bindMode == "loopback" { return nil }
    let existing = mcpConfiguredToken
    if !existing.isEmpty { return existing }
    let minted = UUID().uuidString
    UserDefaults.standard.set(minted, forKey: "ophanim.mcp.token")
    FileHandle.standardError.write(Data(
        ("ophanim: non-loopback MCP HTTP bind - minted bearer token (UserDefaults ophanim.mcp.token):\n"
         + "ophanim: clients must send 'Authorization: Bearer <token>'\n").utf8))
    return minted
}

/// Read-only tool names (catalog annotations + read-only inspect readers): token-exempt.
func mcpTokenExempt(tool name: String) -> Bool {
    if MCPServer.readOnlyTools.contains(name) { return true }
    return ["uitree_read", "screenshot", "inspect_classes", "inspect_element",
            "inspect_class_detail", "inspect_timeline", "inspect_diff",
            "bookmark_list"].contains(name)
}

var mcpConfiguredBind: String {
    let mode = UserDefaults.standard.string(forKey: "ophanim.mcp.bind") ?? "loopback"
    if mode == "specific" {
        let ip = UserDefaults.standard.string(forKey: "ophanim.mcp.bindIP") ?? ""
        return ip.isEmpty ? "loopback" : ip
    }
    return mode
}

/// Resolve a bind mode/address string to a network-order IPv4 address. Falls back to loopback for
/// anything unrecognized so we never accidentally bind wide open.
func mcpResolveBind(_ mode: String) -> in_addr_t {
    switch mode.lowercased() {
    case "loopback", "local", "127.0.0.1": return inet_addr("127.0.0.1")
    case "all", "any", "0.0.0.0", "*":     return in_addr_t(0)   // INADDR_ANY
    default:
        let a = inet_addr(mode)
        return a == INADDR_NONE ? inet_addr("127.0.0.1") : a
    }
}

// MARK: - HTTP transport (loopback :20033, Streamable HTTP over a POSIX socket)

final class MCPHTTPTransport {
    nonisolated(unsafe) static let shared = MCPHTTPTransport()
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "be.ophanim.mcp.http", attributes: .concurrent)
    private(set) var isRunning = false
    private(set) var boundPort: UInt16 = kMCPPort
    private(set) var boundHost = "loopback"

    /// Start the HTTP server on the given port + bind address (defaults to the configured values).
    /// Idempotent; silently no-ops if already running or the address is unavailable.
    func start(port: UInt16? = nil, bind bindArg: String? = nil) {
        guard listenFD < 0 else { return }
        let port = port ?? mcpConfiguredPort
        let bindMode = bindArg ?? mcpConfiguredBind
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = mcpResolveBind(bindMode)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        listenFD = fd
        boundPort = port
        boundHost = bindMode
        isRunning = true
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        isRunning = false
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if listenFD < 0 { return }; continue }
            queue.async { [weak self] in self?.handleClient(client) }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let (method, headers, body) = readRequest(fd) else { return }
        let (status, payload): (String, Data)
        if isCrossOriginOrRebind(headers) {
            // A web page (or a DNS-rebound hostname) is driving us. Native MCP clients send no Origin
            // and a loopback Host. Refuse, so a malicious site can't reach this localhost server to
            // read captured data / change config / launch apps. See isCrossOriginOrRebind.
            (status, payload) = ("403 Forbidden", Data(#"{"error":"forbidden"}"#.utf8))
        } else if method != "POST" {
            (status, payload) = ("405 Method Not Allowed", Data("POST only".utf8))
        } else if let hv = headers["mcp-protocol-version"],
                  !MCPServer.supportedProtocolVersions.contains(hv) {
            // Spec requires MCP-Protocol-Version on every POST. Unsupported value:
            // version error with the supported list (body _meta is gated per-request after).
            let err: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": MCPServer.versionErrorCode, "message": "Unsupported protocol version",
                          "data": ["supported": MCPServer.supportedProtocolVersions,
                                   "requested": hv]]]
            (status, payload) = ("400 Bad Request",
                (try? JSONSerialization.data(withJSONObject: err)) ?? Data())
        } else if let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let refusal = tokenRefusal(msg, headers: headers) {
                (status, payload) = refusal
            } else if let response = MCPServer.shared.handle(msg) {
                let data = (try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])) ?? Data()
                (status, payload) = ("200 OK", data)
            } else {
                (status, payload) = ("202 Accepted", Data())   // notification, no reply
            }
        } else {
            (status, payload) = ("400 Bad Request",
                Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        // No Access-Control-Allow-Origin: this is a local JSON-RPC endpoint for native MCP clients, not
        // a web API. Advertising CORS would let a browser page read responses; we don't want that.
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// True if the request looks like it came from a web page or a DNS-rebound hostname rather than a
    /// native MCP client. Two signals: (1) any `Origin` header - browsers always set it on a cross-site
    /// fetch (and on non-GET same-origin), native clients never do; (2) for the default loopback bind, a
    /// `Host` that isn't a literal loopback address (defeats rebinding, where evil.com resolves to
    /// 127.0.0.1). When the user has explicitly bound to all/■specific interfaces they accepted LAN
    /// exposure, so the Host isn't second-guessed there (the Origin check still applies).
    private func isCrossOriginOrRebind(_ headers: [String: String]) -> Bool {
        if headers["origin"] != nil { return true }
        if boundHost == "loopback", let host = headers["host"]?.lowercased() {
            let name = host.split(separator: ":").first.map(String.init) ?? host
            if !["127.0.0.1", "localhost", "::1"].contains(name) { return true }
        }
        return false
    }

    /// Read one HTTP request: headers until CRLFCRLF, then Content-Length bytes of body. Header names
    /// are returned lowercased.
    /// Bearer-token gate (MD-10 remainder): on non-loopback binds, write tools need
    /// `Authorization: Bearer <token>`. Returns the refusal tuple, or nil to proceed.
    /// Handshake/methods and read-only tools never pay.
    private func tokenRefusal(_ msg: [String: Any], headers: [String: String]) -> (String, Data)? {
        guard let token = mcpRequiredToken(bindMode: boundHost) else { return nil }
        guard (msg["method"] as? String) == "tools/call",
              let params = msg["params"] as? [String: Any],
              let name = params["name"] as? String,
              !mcpTokenExempt(tool: name) else { return nil }
        let presented = headers["authorization"] ?? ""
        guard presented == "Bearer \(token)" else {
            let err: [String: Any] = ["jsonrpc": "2.0", "id": msg["id"] ?? NSNull(),
                "error": ["code": -32001, "message": "bearer token required for '\(name)' "
                    + "on non-loopback HTTP (UserDefaults ophanim.mcp.token)"]]
            return ("401 Unauthorized", (try? JSONSerialization.data(withJSONObject: err)) ?? Data())
        }
        return nil
    }

    private func readRequest(_ fd: Int32) -> (method: String, headers: [String: String], body: Data)? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 14)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Int? = buf.range(of: sep)?.upperBound
        // Read until we have the full header block.
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: sep)?.upperBound
        }
        guard let bodyStart = headerEnd,
              let headerText = String(data: buf.prefix(bodyStart), encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let method = lines.first?.components(separatedBy: " ").first ?? "GET"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        // Read the remaining body bytes.
        while buf.count - bodyStart < contentLength {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        return (method, headers, buf.suffix(from: bodyStart))
    }
}
