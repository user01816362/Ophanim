//
//  InspectCommandPump.swift
//  Galgal
//
//  The guest side of InspectProtocol. A main-runloop timer polls the shared log directory for
//  a command file, executes it, and writes the matching response file. Design constraints:
//  - gated on OPConfig.agentMode (re-read per poll: flipping the switch applies live, and the
//    pump never runs for apps that never opted in);
//  - main thread only (UIKit snapshotting and touch delivery are main-thread work; the timer
//    fires there, so no hop, no race with the render server beyond what drawHierarchy owns);
//  - single-slot: a command is claimed by deleting it before execution, so a slow op can never
//    run twice and a crashed op leaves no command behind to wedge the next poll;
//  - every failure path writes a failure response. The host waits on the response file, so
//    "no response" must mean "not done", never "crashed silently".
//

import Foundation
import UIKit

@objcMembers
class InspectBoot: NSObject {
    private static var started = false

    /// Called from GalgalLoader's constructor. Starts nothing unless Agent Mode is on: the
    /// default path costs one config read and returns. The latch is set only on success, so
    /// enabling later takes effect on next relaunch; disabling stops the pump within one poll
    /// (live gate in poll()). One file read beats a darwin observer here.
    static func maybeStart() {
        guard !started else { return }
        guard OPConfigLoader.load().agentMode else { return }
        started = true
        InspectCommandPump.shared.start()
    }
}

final class InspectCommandPump: NSObject {
    static let shared = InspectCommandPump()

    private var timer: Timer?
    private static var lastBeat = Date.distantPast

    private var directory: URL? {
        let dir = OPPaths.logDirectory(forBundleID: Bundle.main.bundleIdentifier ?? "")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Starts the half-second main-runloop poll (common modes, so tracking never stalls it).
    /// Idempotent: a second start is a no-op.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Common modes: the default-mode timer stalls during scrolling/tracking, delaying a
        // tap past the gesture it was meant to hit. Polls are idempotent reads, so firing
        // during tracking is correct here.
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }


    /// Filenames embed a guest-untrusted id: restrict to UUID-safe characters so a planted
    /// command file can never write outside the log directory.
    private func saneID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: "[^A-Za-z0-9-]", options: .regularExpression) == nil
    }

    private func poll() {
        // Live gate: turning Agent Mode off stops serving within one interval. The timer itself
        // stays (cheap); commands simply stop being claimed. Turning it ON needs a relaunch
        // (InspectBoot latch) - the doc states this direction explicitly, not "no live re-check".
        let config = OPConfigLoader.load()
        guard config.agentMode, let dir = directory else { return }
        // One config read per poll: the redaction flag rides into execute instead of
        // re-reading the plist per op (a poll used to read it 2-3 times).
        let redacted = !config.inspectDisableRedaction
        // Pump-alive heartbeat (phase-5 observability): one tiny file per minute so the host
        // can tell "guest pump silent - relaunch" apart from "app not running" and from a
        // merely-slow op. Content is the beat timestamp; readers prefer mtime, content is backup.
        let now = Date()
        if now.timeIntervalSince(Self.lastBeat) >= 60 {
            Self.lastBeat = now
            let beat = dir.appendingPathComponent(InspectWire.pumpAlive)
            try? ISO8601DateFormatter().string(from: now).write(to: beat, atomically: true, encoding: .utf8)
        }
        let cmdURL = dir.appendingPathComponent(InspectWire.command)
        // Claim by atomic rename, not read-then-delete: a host write landing between our read
        // and delete would otherwise be destroyed unexecuted. moveItem fails if the source is
        // already gone, which is how a second pump (should one ever exist) loses the race.
        let claimURL = dir.appendingPathComponent(InspectWire.claimName())
        do {
            try FileManager.default.moveItem(at: cmdURL, to: claimURL)
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: claimURL) }
        guard let data = try? Data(contentsOf: claimURL),
              let cmd = try? JSONDecoder().decode(InspectCommand.self, from: data),
              saneID(cmd.id) else {
            // Unparseable or hostile command: still answer when an id can be recovered, so the
            // host hears failure instead of burning its full timeout on silence.
            var recovered: String? = nil
            if let data = try? Data(contentsOf: claimURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = obj["id"] as? String, saneID(id) {
                recovered = id
            }
            if let recovered,
               let out = try? JSONEncoder().encode(InspectResponse.failure(id: recovered, "unparseable inspect command")) {
                try? out.write(to: dir.appendingPathComponent(InspectWire.responseName(for: recovered)), options: .atomic)
            }
            return
        }
        // One bad op can't wedge the channel: a throw inside execute still answers with
        // the op's id (claim already removed), so the host moves on instead of burning
        // its full 60 s timeout on silence. Swift cannot catch the ObjC exceptions a walk,
        // screenshot, or touch synthesis can raise - the ObjC wrapper can.
        var exName: NSString?
        var exReason: NSString?
        let out = OPHookGuardProtect({
            guard let d = try? JSONEncoder().encode(self.execute(cmd, redacted: redacted)) else { return nil }
            return NSData(data: d)
        }, &exName, &exReason) as? NSData
        if let nsdata = out {
            try? (nsdata as Data).write(to: dir.appendingPathComponent(InspectWire.responseName(for: cmd.id)), options: .atomic)
        } else {
            OPCrashTrapNoteHook("inspect.\(cmd.op.rawValue)")
            let failure = InspectResponse.failure(
                id: cmd.id,
                "inspect op \(cmd.op.rawValue) threw \((exName as String?) ?? "?"): \((exReason as String?) ?? "")")
            if let data = try? JSONEncoder().encode(failure) {
                try? data.write(to: dir.appendingPathComponent(InspectWire.responseName(for: cmd.id)), options: .atomic)
            }
        }
    }

    /// Cut flags to the additive truncatedBy list (nil when nothing cut, preserving the
    /// legacy truncated-bool-only shape for uncut reads).
    private func cutBy(_ depthCut: Bool, _ nodeCut: Bool) -> [String]? {
        var by: [String] = []
        if depthCut { by.append("depth") }
        if nodeCut { by.append("nodes") }
        return by.isEmpty ? nil : by
    }

    /// Executes one claimed command against the live UI and builds its response.
    /// Every op either answers or fails stated — never silent, never a guess.
    ///
    /// - Parameter cmd: Decoded host command.
    /// - Parameter redacted: Whether secure-field text is masked (rides in from the poll's config read).
    /// - Returns: Response written back to the shared log directory.
    private func execute(_ cmd: InspectCommand, redacted: Bool) -> InspectResponse {
        switch cmd.op {
        case .uiTree:
            let mode = cmd.mode ?? .full
            // Agent-narrowable caps only ever narrow the hard ceilings: the guest clamps,
            // never raises. Omitted means the historic 24/2000 behavior, byte-identical.
            let depthCap = min(max(cmd.depthLimit ?? Inspector.maxDepth, 1), Inspector.maxDepth)
            let nodeCap = min(max(cmd.nodeLimit ?? Inspector.maxNodes, 1), Inspector.maxNodes)
            // Subtree-scoped read: elementId doubles as the walk root (additive: nil/empty
            // means the whole forest, byte-identical to before). The walk is seeded with the
            // root's FULL positional id, so every descendant id stays globally resolvable -
            // a subtree read returns tappable ids, not a renumbered island. Unresolvable
            // roots fail stated with the same vocabulary as taps, never a guessed subtree.
            if let rootId = cmd.elementId, !rootId.isEmpty, rootId != "root" {
                guard let (view, window, _) = Inspector.resolve(elementId: rootId, mode: mode) else {
                    return .failure(id: cmd.id, "rootId '\(rootId)' no longer resolves - take a fresh tree")
                }
                let (node, _, dCut, nCut) = Inspector.walk(view, id: rootId, window: window,
                                                    depth: 0, budget: nodeCap,
                                                    redact: redacted,
                                                    mode: mode, filter: cmd.filter,
                                                    maxDepth: depthCap)
                guard let node = node else {
                    return .failure(id: cmd.id, "rootId '\(rootId)' matched nothing under the current filter")
                }
                return InspectResponse(id: cmd.id, ok: true, error: nil,
                                       truncated: dCut || nCut, truncatedBy: cutBy(dCut, nCut),
                                       tree: node,
                                       imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                       acted: nil, targetClass: nil)
            }
            let (nodes, truncated, by, frameworks, evidence, rnArch, scene, vcs) = Inspector.snapshot(redact: redacted,
                                                            mode: mode,
                                                            filter: cmd.filter,
                                                            maxDepth: depthCap,
                                                            maxNodes: nodeCap)
            // Forest root: one synthetic node so the payload shape is uniform.
            let root = InspectNode(id: "root", cls: "Windows", role: "container", frame: [0, 0, 0, 0],
                                   text: nil, placeholder: nil, axLabel: nil, axIdentifier: nil,
                                   enabled: true, secure: false, framework: nil, layer: nil,
                                   vc: nil, children: nodes)
            var rsp = InspectResponse(id: cmd.id, ok: true, error: nil,
                                   truncated: truncated, truncatedBy: by.isEmpty ? nil : by,
                                   tree: root,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: nil)
            if !frameworks.isEmpty { rsp.frameworksDetected = frameworks }
            if !evidence.isEmpty { rsp.frameworkEvidence = evidence }
            if !vcs.isEmpty { rsp.vcs = vcs }
            rsp.rnArch = rnArch
            rsp.scene = scene
            return rsp

        case .screenshot:
            // Optional element crop: resolve in the caller's mode (same rule as tap),
            // crop to the element frame in window points (guest maps to pixels exactly).
            var crop: CGRect? = nil
            if let elementId = cmd.elementId, !elementId.isEmpty {
                guard let hit = Inspector.resolve(elementId: elementId, mode: cmd.mode ?? .full) else {
                    return .failure(id: cmd.id, "element '\(elementId)' no longer resolves - take a fresh tree in the same mode")
                }
                guard hit.window === Inspector.keyWindow() else {
                    return .failure(id: cmd.id, "element '\(elementId)' is not in the key window - take a fresh tree")
                }
                crop = hit.view.convert(hit.view.bounds, to: hit.window)
            }
            guard let shot = InspectorScreenshot.capture(redact: redacted,
                                                         annotate: cmd.annotate ?? false,
                                                         cropTo: crop) else {
                return .failure(id: cmd.id, crop == nil ? "no window available for capture"
                                                        : "element frame outside capture")
            }
            let key = Inspector.keyWindowFramework()
            var shot_rsp = InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: shot.data.base64EncodedString(),
                                   mimeType: "image/jpeg", width: shot.width, height: shot.height,
                                   acted: nil, targetClass: nil)
            if !key.frameworks.isEmpty { shot_rsp.frameworksDetected = key.frameworks }
            shot_rsp.rnArch = key.rnArch
            shot_rsp.scene = key.scene
            return shot_rsp

        case .tap:
            // Touches only ever land in the key window (the touch path targets it): an element
            // resolved in any other window fails stated, rather than tapping its coordinates in
            // the wrong window.
            guard let key = Inspector.keyWindow() else {
                return .failure(id: cmd.id, "no key window to tap in")
            }
            let point: CGPoint?
            var cls: String? = nil
            if let elementId = cmd.elementId, !elementId.isEmpty {
                guard let hit = Inspector.resolve(elementId: elementId, mode: cmd.mode ?? .full) else {
                    return .failure(id: cmd.id, "element '\(elementId)' no longer resolves - take a fresh tree in the same mode")
                }
                guard hit.window === key else {
                    return .failure(id: cmd.id, "element '\(elementId)' is not in the key window - take a fresh tree")
                }
                let frame = hit.view.convert(hit.view.bounds, to: key)
                point = CGPoint(x: frame.midX, y: frame.midY)
                cls = hit.cls
            } else if let x = cmd.x, let y = cmd.y {
                point = denormalize(x: x, y: y, in: key)
            } else {
                return .failure(id: cmd.id, "tap needs elementId or x/y")
            }
            guard let point = point else {
                return .failure(id: cmd.id, "tap coordinates out of range")
            }
            let result = InspectorActivator.tap(at: point, in: key)
            if !result.acted {
                return .failure(id: cmd.id, "touch refused at (\(Int(point.x)), \(Int(point.y)))")
            }
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: true, targetClass: cls ?? result.targetClass)

        case .pick:
            guard let x = cmd.x, let y = cmd.y else {
                return .failure(id: cmd.id, "pick needs x/y, each in 0...1")
            }
            guard let hit = Inspector.pick(x: x, y: y, mode: cmd.mode ?? .full) else {
                return .failure(id: cmd.id, "nothing hittable at (\(x), \(y)) - take a fresh tree")
            }
            var pick_rsp = InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: hit.cls)
            pick_rsp.elementId = hit.id
            pick_rsp.viewController = hit.vc
            return pick_rsp

        case .pasteboard:
            var pb_rsp = InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: nil)
            pb_rsp.pasteboard = InspectorActivator.pasteboardString()
            return pb_rsp

        case .focus:
            let info = InspectorActivator.focusInfo()
            var focus_rsp = InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: info.focusClass)
            focus_rsp.focusClass = info.focusClass
            focus_rsp.appState = info.appState
            return focus_rsp

        case .swipe:
            // Same key-window contract as tap: the touch path targets it, so anything else
            // fails stated instead of swiping the wrong window.
            guard let key = Inspector.keyWindow() else {
                return .failure(id: cmd.id, "no key window to swipe in")
            }
            guard let x1 = cmd.x1, let y1 = cmd.y1, let x2 = cmd.x2, let y2 = cmd.y2,
                  (0...1).contains(x1), (0...1).contains(y1),
                  (0...1).contains(x2), (0...1).contains(y2) else {
                return .failure(id: cmd.id, "swipe needs x1/y1/x2/y2, each in 0...1")
            }
            let b = key.bounds
            let from = CGPoint(x: b.origin.x + CGFloat(x1) * b.width,
                               y: b.origin.y + CGFloat(y1) * b.height)
            let to = CGPoint(x: b.origin.x + CGFloat(x2) * b.width,
                             y: b.origin.y + CGFloat(y2) * b.height)
            let result = InspectorActivator.swipe(from: from, to: to, steps: cmd.steps ?? 8, in: key)
            if !result.acted {
                return .failure(id: cmd.id, "swipe refused at (\(Int(from.x)), \(Int(from.y)))")
            }
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: true, targetClass: result.targetClass)

        case .setText:
            guard let text = cmd.text else {
                return .failure(id: cmd.id, "setText needs text")
            }
            guard let elementId = cmd.elementId, !elementId.isEmpty else {
                return .failure(id: cmd.id, "setText needs elementId - take a tree, pick the field")
            }
            guard let hit = Inspector.resolve(elementId: elementId, mode: cmd.mode ?? .full) else {
                return .failure(id: cmd.id, "element '\(elementId)' no longer resolves - take a fresh tree in the same mode")
            }
            guard hit.window === Inspector.keyWindow() else {
                return .failure(id: cmd.id, "element '\(elementId)' is not in the key window - take a fresh tree")
            }
            guard InspectorActivator.setText(text, in: hit.view) else {
                // Fallback for engine-rendered inputs (Flutter bridge, custom controls):
                // tap to focus, then insertText into the first responder. Web content
                // refuses inside typeText (JS owns that state).
                let frame = hit.view.convert(hit.view.bounds, to: hit.window)
                let point = CGPoint(x: frame.midX, y: frame.midY)
                guard InspectorActivator.typeText(text, at: point, in: hit.window).acted else {
                    return .failure(id: cmd.id, "element '\(elementId)' (\(hit.cls)) is not a text field")
                }
                return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                       imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                       acted: true, targetClass: hit.cls)
            }
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: true, targetClass: hit.cls)

        case .classes:
            let (names, total) = Inspector.runtimeClasses(filter: cmd.filter, limit: cmd.limit ?? 200)
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: nil,
                                   classes: names, totalCount: total)

        case .classDetail:
            guard let name = cmd.className, !name.isEmpty else {
                return .failure(id: cmd.id, "classDetail needs className - find one with inspect_classes first")
            }
            guard let detail = Inspector.classDetail(name: name) else {
                return .failure(id: cmd.id, "class '\(name)' is not loaded - check the exact runtime name with inspect_classes")
            }
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: nil,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: nil,
                                   classDetail: detail)

        case .element:
            guard let elementId = cmd.elementId, !elementId.isEmpty else {
                return .failure(id: cmd.id, "element needs elementId - take a tree first")
            }
            let mode = cmd.mode ?? .full
            guard let hit = Inspector.resolve(elementId: elementId, mode: mode) else {
                return .failure(id: cmd.id, "element '\(elementId)' no longer resolves - take a fresh tree in the same mode")
            }
            // Full-subtree detail regardless of query mode: detail shows everything beneath.
            let (node, _, _, _) = Inspector.walk(hit.view, id: elementId, window: hit.window,
                                              depth: 0, budget: Inspector.maxNodes,
                                              redact: redacted, mode: .full, filter: nil)
            guard let node = node else {
                return .failure(id: cmd.id, "element '\(elementId)' vanished mid-read")
            }
            return InspectResponse(id: cmd.id, ok: true, error: nil, truncated: nil, tree: node,
                                   imageBase64: nil, mimeType: nil, width: nil, height: nil,
                                   acted: nil, targetClass: nil,
                                   superclasses: Inspector.superclasses(of: hit.view),
                                   viewController: Inspector.viewController(of: hit.view))
        }
    }

    /// Converts normalized 0...1 coordinates into window points. Out-of-range returns nil.
    ///
    /// - Parameter x: Normalized horizontal position.
    /// - Parameter y: Normalized vertical position.
    /// - Parameter window: Window whose bounds denormalize against.
    /// - Returns: Window point, or nil when out of range.
    private func denormalize(x: Double, y: Double, in window: UIWindow) -> CGPoint? {
        let b = window.bounds
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: b.origin.x + CGFloat(x) * b.width,
                       y: b.origin.y + CGFloat(y) * b.height)
    }
}
