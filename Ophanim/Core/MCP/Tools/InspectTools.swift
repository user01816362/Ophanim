//
//  InspectTools.swift
//  Ophanim
//
//  Agent-Mode tools over MCP (ported): screenshot, UI-tree read, gestures, class
//  inventory, snapshots, bookmarks. Single gate (InspectGate.requireLive); wire via
//  InspectControl; stores via SnapshotStore/BookmarkStore. Destructive tools preview
//  by default (isDryRun, OLD safety contract): pass dryRun:false to execute.

import Foundation

enum InspectTools {

    /// Snapshot bracketing shared by tap/swipe/set_text: optional pre/post tree pins
    /// around one inspect op. `capture` builds the pin for a phase ("pre"/"post" is
    /// folded into the trigger name by the caller); `perform` runs the op and returns
    /// its result payload. One shape, three ops - no copy-pasted pre/post blocks.
    static func withSnapshots(id: Any?, snap: (pre: Bool, post: Bool),
                       capture: (String) throws -> String,
                       perform: () throws -> [String: Any]) throws -> [String: Any] {
        var extra: [String: Any] = [:]
        if snap.pre { extra["preSnapshot"] = try capture("pre") }
        let payload = try perform()
        if snap.post { extra["postSnapshot"] = try capture("post") }
        return MCPServer.toolResult(id, payload.merging(extra) { _, new in new })
    }

    /// Tree-read arguments shared by uitree_read and inspect_snapshot (mode, substring
    /// filter, subtree root, agent budget caps). Parsed once here so the two readers
    /// cannot drift.
    static func treeArgs(_ args: [String: Any]) throws
        -> (mode: InspectMode, filter: String?, rootId: String?, depth: Int?, nodes: Int?) {
        let mode = try inspectMode(args)
        let filter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rootId = (args["rootId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let caps = try treeCaps(args)
        return (mode, filter, rootId, caps.depth, caps.nodes)
    }

    /// Dispatch for the three Inspect tools. Gate first: Agent Mode off means refuse, stated -
    /// never an empty tree or a black screenshot that looks like success.
    static func runInspectTool(_ id: Any?, _ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let bid = try ToolRouter.requireBundleID(args)
        // Single gate (InspectGate.requireLive): not-installed / not-running / host-setting
        // off, each naming its own fix; guest-pump silent stays at the timeout site.
        // Liveness comes from the shared definition, never a bare NSWorkspace check.
        let (settings, redacted) = try InspectGate.requireLive(bundleID: bid)

        switch name {
        case "uitree_read":
            // The tree ships as a JSON *string* in a text block, not as nested structured
            // content: real trees nest 20+ levels and blow past client object-depth limits
            // (hit at 32 on first live use). The summary stays structured for filtering.
            let t = try treeArgs(args)
            let rsp = try InspectControl.transact(bundleID: bid, op: .uiTree,
                                                  elementId: t.rootId,
                                                  mode: t.mode, filter: t.filter,
                                                  depthLimit: t.depth, nodeLimit: t.nodes)
            guard let tree = rsp.tree,
                  let data = try? JSONEncoder().encode(tree),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolRouter.bail("uitree_read returned an undecodable tree for \(bid)")
            }
            // Subtree reads return the rooted node (whose own id is rootId), not the forest:
            // windows is 1 by construction and rootId echoes so callers can pair reads.
            var summary: [String: Any] = ["bundleID": bid,
                                          "redacted": redacted,
                                          "truncated": rsp.truncated ?? false,
                                          "windows": t.rootId == nil ? (tree.children).count : 1]
            if let rootId = t.rootId { summary["rootId"] = rootId }
            if let by = rsp.truncatedBy, !by.isEmpty { summary["truncatedBy"] = by }
            return MCPServer.result(id, [
                "resultType": "complete",
                "content": [["type": "text", "text": text]],
                "structuredContent": summary
            ])

        case "screenshot":
            let rsp = try InspectControl.transact(bundleID: bid, op: .screenshot)
            guard let b64 = rsp.imageBase64, !b64.isEmpty else {
                throw ToolRouter.bail("screenshot captured nothing for \(bid) - is a window visible?")
            }
            let w = rsp.width ?? 0, h = rsp.height ?? 0
            return MCPServer.toolResultImage(id, base64: b64, mimeType: rsp.mimeType ?? "image/jpeg",
                                   summary: "screenshot \(w)x\(h) redacted=\(redacted)",
                                   structured: ["bundleID": bid, "width": w, "height": h,
                                                "redacted": redacted])

        case "tap_element":
            let elementId = (args["elementId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // JSON integers arrive as Int, not Double: accept both, so 0/1 coordinates validate.
            let x = ToolRouter.coerceDouble(args, "x")
            let y = ToolRouter.coerceDouble(args, "y")
            guard elementId != nil || (x != nil && y != nil) else {
                throw ToolRouter.bail("tap_element needs elementId (preferred) or both x and y in 0...1")
            }
            if let x, let y, !(0...1).contains(x) || !(0...1).contains(y) {
                throw ToolRouter.bail("x and y must each be in 0...1, got (\(x), \(y))")
            }
            let mode = try inspectMode(args)
            let snap = try SnapshotCaptureArg.parse(args)
            return try withSnapshots(id: id, snap: snap, capture: { phase in
                try captureTreeSnapshot(
                    bid, trigger: "\(phase)-tap", op: "tap", mode: mode, redacted: redacted,
                    elementId: elementId, x: x, y: y).id
            }, perform: {
                let rsp = try InspectControl.transact(bundleID: bid, op: .tap,
                                                      elementId: elementId, x: x, y: y,
                                                      mode: mode)
                return ["bundleID": bid,
                        "acted": rsp.acted ?? false,
                        "targetClass": rsp.targetClass ?? "unknown"]
            })

        case "swipe":
            func norm(_ key: String) throws -> Double {
                guard let v = ToolRouter.coerceDouble(args, key),
                      (0...1).contains(v) else {
                    throw ToolRouter.bail("\(key) is required in 0...1")
                }
                return v
            }
            let x1 = try norm("x1"), y1 = try norm("y1"), x2 = try norm("x2"), y2 = try norm("y2")
            let steps = ToolRouter.coerceInt(args, "steps") ?? 8
            guard (1...20).contains(steps) else { throw ToolRouter.bail("steps must be 1...20") }
            let snap = try SnapshotCaptureArg.parse(args)
            return try withSnapshots(id: id, snap: snap, capture: { phase in
                try captureTreeSnapshot(
                    bid, trigger: "\(phase)-swipe", op: "swipe", mode: .full, redacted: redacted,
                    x1: x1, y1: y1, x2: x2, y2: y2, steps: steps).id
            }, perform: {
                let rsp = try InspectControl.transact(bundleID: bid, op: .swipe,
                                                      x1: x1, y1: y1, x2: x2, y2: y2, steps: steps)
                return ["bundleID": bid,
                        "acted": rsp.acted ?? false,
                        "targetClass": rsp.targetClass ?? "unknown"]
            })

        case "set_text":
            guard let elementId = (args["elementId"] as? String), !elementId.isEmpty else {
                throw ToolRouter.bail("set_text needs elementId - take a tree, pick the field")
            }
            guard let text = args["text"] as? String else {
                throw ToolRouter.bail("set_text needs text")
            }
            let mode = try inspectMode(args)
            let snap = try SnapshotCaptureArg.parse(args)
            return try withSnapshots(id: id, snap: snap, capture: { phase in
                try captureTreeSnapshot(
                    bid, trigger: "\(phase)-setText", op: "setText", mode: mode,
                    redacted: redacted, elementId: elementId,
                    textLength: text.count).id
            }, perform: {
                let rsp = try InspectControl.transact(bundleID: bid, op: .setText,
                                                      elementId: elementId,
                                                      mode: mode, text: text)
                return ["bundleID": bid,
                        "acted": rsp.acted ?? false,
                        "targetClass": rsp.targetClass ?? "unknown"]
            })

        case "inspect_classes":
            let filter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let limit = (args["limit"] as? Int) ?? 200
            guard (1...2000).contains(limit) else { throw ToolRouter.bail("limit must be 1...2000") }
            let rsp = try InspectControl.transact(bundleID: bid, op: .classes,
                                                  filter: filter, limit: limit)
            return MCPServer.toolResult(id, ["bundleID": bid,
                                   "totalLoaded": rsp.totalCount ?? 0,
                                   "returned": rsp.classes?.count ?? 0,
                                   "classes": rsp.classes ?? []])

        case "inspect_element":
            guard let elementId = (args["elementId"] as? String), !elementId.isEmpty else {
                throw ToolRouter.bail("inspect_element needs elementId - take a tree first")
            }
            let rsp = try InspectControl.transact(bundleID: bid, op: .element,
                                                  elementId: elementId,
                                                  mode: try inspectMode(args))
            guard let node = rsp.tree,
                  let data = try? JSONEncoder().encode(node),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolRouter.bail("inspect_element returned an undecodable node for \(bid)")
            }
            return MCPServer.result(id, [
                "resultType": "complete",
                "content": [["type": "text", "text": text]],
                "structuredContent": ["bundleID": bid,
                                      "elementId": elementId,
                                      "superclasses": rsp.superclasses ?? [],
                                      "viewController": rsp.viewController ?? "none"]
            ])

        case "inspect_class_detail":
            guard let name = (args["className"] as? String), !name.isEmpty else {
                throw ToolRouter.bail("inspect_class_detail needs className - find one with inspect_classes first")
            }
            let rsp = try InspectControl.transact(bundleID: bid, op: .classDetail,
                                                  className: name)
            guard let detail = rsp.classDetail,
                  let data = try? JSONEncoder().encode(detail),
                  let text = String(data: data, encoding: .utf8) else {
                throw ToolRouter.bail("inspect_class_detail returned nothing usable for '\(name)'")
            }
            return MCPServer.result(id, [
                "resultType": "complete",
                "content": [["type": "text", "text": text]],
                "structuredContent": ["bundleID": bid,
                                      "name": detail.name,
                                      "isMeta": detail.isMeta,
                                      "methodCount": detail.methods.count,
                                      "classMethodCount": detail.classMethods.count,
                                      "truncated": detail.truncated]
            ])

        case "inspect_snapshot":
            let t = try treeArgs(args)
            let mode = t.mode, filter = t.filter, rootId = t.rootId
            let caps = (depth: t.depth, nodes: t.nodes)
            let withShot = (args["withScreenshot"] as? Bool) ?? false
            let treeRsp = try InspectControl.transact(bundleID: bid, op: .uiTree,
                                                      elementId: rootId,
                                                      mode: mode, filter: filter,
                                                      depthLimit: caps.depth,
                                                      nodeLimit: caps.nodes)
            guard let tree = treeRsp.tree,
                  let treeData = try? JSONEncoder().encode(tree) else {
                throw ToolRouter.bail("inspect_snapshot read an undecodable tree for \(bid)")
            }
            var jpeg: Data? = nil, w: Int? = nil, h: Int? = nil
            if withShot {
                let shot = try InspectControl.transact(bundleID: bid, op: .screenshot)
                guard let b64 = shot.imageBase64, !b64.isEmpty,
                      let raw = Data(base64Encoded: b64) else {
                    throw ToolRouter.bail("inspect_snapshot captured nothing - is a window visible?")
                }
                jpeg = raw; w = shot.width; h = shot.height
            }
            let man = SnapshotStore.capture(
                bundleID: bid, trigger: "manual", opRef: nil,
                mode: mode, filter: filter, rootId: rootId,
                depthLimit: caps.depth ?? InspectCaps.depth,
                nodeLimit: caps.nodes ?? InspectCaps.nodes,
                redacted: redacted,
                truncated: treeRsp.truncated ?? false,
                truncatedBy: treeRsp.truncatedBy,
                tree: tree, treeBytes: treeData, jpeg: jpeg, width: w, height: h)
            var payload: [String: Any] = [
                "bundleID": bid, "id": man.id, "capturedAt": man.capturedAt,
                "trigger": man.trigger, "redacted": man.redacted,
                "truncated": man.truncated, "nodes": man.nodes,
                "treeHash": man.treeHash,
                "depthLimit": man.depthLimit, "nodeLimit": man.nodeLimit]
            if let by = man.truncatedBy, !by.isEmpty { payload["truncatedBy"] = by }
            if let shotFile = man.shotFile { payload["shotFile"] = shotFile }
            return MCPServer.toolResult(id, payload)

        case "inspect_timeline":
            let limit = (args["limit"] as? Int) ?? 20
            guard limit >= 1 else { throw ToolRouter.bail("limit must be >= 1") }
            let trigger = (args["trigger"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var all = SnapshotStore.list(bundleID: bid)
            if let trigger { all = all.filter { $0.trigger == trigger } }
            let page = Array(all.suffix(limit))
            var payload: [String: Any] = [
                "bundleID": bid, "count": page.count, "total": all.count,
                "snapshots": page.map { manifestSummary($0) }]
            if page.count >= 2 {
                let (events, partial, reason) = SnapshotStore.diff(
                    from: page[page.count - 2], to: page[page.count - 1])
                var summary: [String: Any] = [
                    "from": page[page.count - 2].id, "to": page[page.count - 1].id,
                    "eventCount": events.count,
                    "flips": events.filter { ($0["event"] as? String) == "class_flip" }.count,
                    "partial": partial]
                if let reason { summary["reason"] = reason }
                payload["latestPairDiff"] = summary
            }
            return MCPServer.toolResult(id, payload)

        case "inspect_diff":
            let all = SnapshotStore.list(bundleID: bid)
            guard !all.isEmpty else {
                throw ToolRouter.bail("no snapshots for \(bid) - capture with inspect_snapshot first")
            }
            let toID = (args["to"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let fromID = (args["from"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let b = toID.flatMap({ SnapshotStore.load(bundleID: bid, id: $0) }) ?? all.last else {
                throw ToolRouter.bail("snapshot '\(toID ?? "")' not found for \(bid)")
            }
            let a: SnapshotManifest
            if let fromID {
                guard let found = SnapshotStore.load(bundleID: bid, id: fromID) else {
                    throw ToolRouter.bail("snapshot '\(fromID)' not found for \(bid)")
                }
                a = found
            } else {
                let idx = all.lastIndex(where: { $0.id == b.id }) ?? (all.count - 1)
                guard idx > 0 else {
                    throw ToolRouter.bail("only one snapshot for \(bid) - capture another to diff")
                }
                a = all[idx - 1]
            }
            guard a.mode == b.mode && a.filter == b.filter && a.rootId == b.rootId
                && a.depthLimit == b.depthLimit && a.nodeLimit == b.nodeLimit else {
                throw ToolRouter.bail("snapshots \(a.id) (\(a.mode)/\(a.filter ?? "-")/\(a.rootId ?? "-")/d\(a.depthLimit)n\(a.nodeLimit)) and "
                    + "\(b.id) (\(b.mode)/\(b.filter ?? "-")/\(b.rootId ?? "-")/d\(b.depthLimit)n\(b.nodeLimit)) differ in mode, filter, root, or caps - "
                    + "diff only same-walk pairs, like element ids resolve only in one mode")
            }
            let (events, partial, reason) = SnapshotStore.diff(from: a, to: b)
            var payload: [String: Any] = [
                "bundleID": bid, "from": a.id, "to": b.id,
                "partial": partial, "events": events]
            if let reason { payload["reason"] = reason }
            return MCPServer.toolResult(id, payload)

        case "inspect_clear_snapshots":
            let (files, bytes) = SnapshotStore.inventory(bundleID: bid)
            if isDryRun(args) {
                return MCPServer.toolResult(id, ["dryRun": true, "bundleID": bid,
                                       "wouldRemove": files.map(\.path),
                                       "count": files.count, "bytes": bytes])
            }
            let cleared = SnapshotStore.clear(bundleID: bid)
            return MCPServer.toolResult(id, ["bundleID": bid,
                                   "removed": files.map(\.path),
                                   "count": cleared.removed, "bytes": bytes])

        case "bookmark_add":
            guard let kind = (args["kind"] as? String),
                  ["class", "element", "symbol"].contains(kind) else {
                throw ToolRouter.bail("bookmark_add needs kind: class, element, or symbol")
            }
            let pre = BookmarkStore.load(bundleID: bid)
            guard pre.bookmarks.count < BookmarkStore.maxBookmarks else {
                throw ToolRouter.bail("bookmark cap reached (\(BookmarkStore.maxBookmarks)) - remove some first")
            }
            var target = BookmarkTarget(kind: kind, className: nil, elementId: nil,
                                        mode: nil, symbol: nil, role: nil, frame: nil,
                                        axLabel: nil, viewController: nil, superclasses: nil)
            var snapshotRef: String? = nil
            switch kind {
            case "class", "symbol":
                guard let name = (args["name"] as? String), !name.isEmpty else {
                    throw ToolRouter.bail("bookmark_add kind \(kind) needs name")
                }
                if kind == "class" { target.className = name } else { target.symbol = name }
            default: // element
                guard let eid = (args["elementId"] as? String), !eid.isEmpty else {
                    throw ToolRouter.bail("bookmark_add kind element needs elementId - take a tree first")
                }
                let mode = try inspectMode(args)
                target.elementId = eid
                target.mode = mode.rawValue
                if let snapID = (args["snapshot"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                    guard let man = SnapshotStore.load(bundleID: bid, id: snapID) else {
                        throw ToolRouter.bail("snapshot '\(snapID)' not found - capture with inspect_snapshot first")
                    }
                    guard man.mode == mode.rawValue else {
                        throw ToolRouter.bail("snapshot '\(snapID)' is mode \(man.mode): element ids only resolve in the mode whose walk produced them")
                    }
                    snapshotRef = man.id
                } else {
                    // Pin evidence at bookmark time: a fresh capture that also lands in the
                    // timeline, so the mark and its proof never separate.
                    guard BookmarkStore.snapshotRefs(bundleID: bid).count < BookmarkStore.maxPins else {
                        throw ToolRouter.bail("pin cap reached (\(BookmarkStore.maxPins)) - pass an existing snapshot instead")
                    }
                    let rsp = try InspectControl.transact(bundleID: bid, op: .uiTree, mode: mode)
                    guard let tree = rsp.tree,
                          let treeData = try? JSONEncoder().encode(tree) else {
                        throw ToolRouter.bail("bookmark_add read an undecodable tree for \(bid)")
                    }
                    snapshotRef = SnapshotStore.capture(
                        bundleID: bid, trigger: "manual", opRef: nil,
                        mode: mode, filter: nil, redacted: redacted,
                        truncated: rsp.truncated ?? false,
                        tree: tree, treeBytes: treeData).id
                }
            }
            let comment = (args["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let tags = (args["tags"] as? [String]) ?? []
            let groupName = (args["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let bm = AgentBookmark(id: BookmarkStore.mintID("bm_"), bundleID: bid,
                                   target: target, comment: comment, tags: tags,
                                   createdAt: BookmarkStore.stamp(),
                                   updatedAt: BookmarkStore.stamp(),
                                   snapshotRef: snapshotRef)
            BookmarkStore.modify(bundleID: bid) { store in
                store.bookmarks.append(bm)
                if let groupName {
                    let gid = resolveBookmarkGroup(in: &store, ref: groupName)
                    if let i = store.groups.firstIndex(where: { $0.id == gid }) {
                        if !store.groups[i].bookmarkIds.contains(bm.id) {
                            store.groups[i].bookmarkIds.append(bm.id)
                            store.groups[i].updatedAt = BookmarkStore.stamp()
                        }
                    }
                }
            }
            var payload: [String: Any] = ["bundleID": bid, "id": bm.id, "kind": kind]
            if let snapshotRef { payload["snapshotRef"] = snapshotRef }
            if let groupName { payload["group"] = groupName }
            return MCPServer.toolResult(id, payload)

        case "bookmark_note":
            guard let refID = (args["ref"] as? String) ?? (args["id"] as? String),
                  !refID.isEmpty else {
                throw ToolRouter.bail("bookmark_note needs id")
            }
            if (args["tags"] as? [String]) != nil
                && (refID.hasPrefix("grp_") || !refID.hasPrefix("bm_")) {
                throw ToolRouter.bail("tags are bookmark-only; groups carry a note")
            }
            var touched: String? = nil
            BookmarkStore.modify(bundleID: bid) { store in
                if let i = store.bookmarks.firstIndex(where: { $0.id == refID }) {
                    if let c = args["comment"] as? String { store.bookmarks[i].comment = c }
                    if let t = args["tags"] as? [String] { store.bookmarks[i].tags = t }
                    store.bookmarks[i].updatedAt = BookmarkStore.stamp()
                    touched = store.bookmarks[i].id
                } else if let i = store.groups.firstIndex(where: { $0.id == refID }) {
                    if let c = args["comment"] as? String { store.groups[i].note = c }
                    store.groups[i].updatedAt = BookmarkStore.stamp()
                    touched = store.groups[i].id
                }
            }
            guard let touched else {
                throw ToolRouter.bail("unknown bookmark or group id '\(refID)'")
            }
            return MCPServer.toolResult(id, ["bundleID": bid, "id": touched,
                                   "updatedAt": BookmarkStore.stamp()])

        case "bookmark_move":
            guard let gref = (args["group"] as? String), !gref.isEmpty else {
                throw ToolRouter.bail("bookmark_move needs group")
            }
            let add = (args["add"] as? [String]) ?? []
            let remove = (args["remove"] as? [String]) ?? []
            // Unknown ids fail stated before anything changes: no silent partial membership.
            let current = BookmarkStore.load(bundleID: bid)
            for x in add + remove
            where !current.bookmarks.contains(where: { $0.id == x }) {
                throw ToolRouter.bail("unknown bookmark id '\(x)' - no membership changed")
            }
            func members(after store: BookmarkStoreData, gid: String) -> [String] {
                var m = store.groups.first(where: { $0.id == gid })?.bookmarkIds ?? []
                m.append(contentsOf: add.filter { !m.contains($0) })
                m.removeAll(where: { remove.contains($0) })
                return m
            }
            if isDryRun(args) {
                let (gid, name, created) = peekBookmarkGroup(in: current, ref: gref)
                return MCPServer.toolResult(id, ["dryRun": true, "bundleID": bid,
                                       "group": name, "groupId": gid,
                                       "wouldCreateGroup": created,
                                       "added": add, "removed": remove,
                                       "members": members(after: current, gid: gid)])
            }
            var gid = ""
            BookmarkStore.modify(bundleID: bid) { store in
                gid = resolveBookmarkGroup(in: &store, ref: gref)
                if let i = store.groups.firstIndex(where: { $0.id == gid }) {
                    store.groups[i].bookmarkIds = members(after: store, gid: gid)
                    store.groups[i].updatedAt = BookmarkStore.stamp()
                }
            }
            let after = BookmarkStore.load(bundleID: bid)
            return MCPServer.toolResult(id, ["bundleID": bid, "group": gref, "groupId": gid,
                                   "added": add, "removed": remove,
                                   "members": members(after: after, gid: gid)])

        case "bookmark_list":
            let limit = (args["limit"] as? Int) ?? 200
            guard limit >= 1 else { throw ToolRouter.bail("limit must be >= 1") }
            let kind = (args["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let kind, !["class", "element", "symbol"].contains(kind) {
                throw ToolRouter.bail("kind must be class, element, or symbol")
            }
            let tag = (args["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let gref = (args["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let checkFresh = (args["checkFresh"] as? Bool) ?? false
            let store = BookmarkStore.load(bundleID: bid)
            var list = store.bookmarks
            if let kind { list = list.filter { $0.target.kind == kind } }
            if let tag { list = list.filter { $0.tags.contains(tag) } }
            if let gref {
                guard let g = store.groups.first(where: { $0.id == gref || $0.name == gref }) else {
                    throw ToolRouter.bail("unknown group '\(gref)'")
                }
                let ids = Set(g.bookmarkIds)
                list = list.filter { ids.contains($0.id) }
            }
            let page = Array(list.prefix(limit))
            // Freshness: one guest tree read per distinct pinned walk, hashed against the
            // pinned manifest. Default off - each check costs a single-slot transaction.
            var freshHashes: [String: String?] = [:]
            if checkFresh {
                let walks = Set(page.compactMap { b -> String? in
                    guard b.target.kind == "element", let ref = b.snapshotRef,
                          let man = SnapshotStore.load(bundleID: bid, id: ref) else { return nil }
                    return "\(man.mode)|\(man.filter ?? "")"
                })
                for walk in walks {
                    let parts = walk.split(separator: "|", omittingEmptySubsequences: false)
                        .map(String.init)
                    let mode = InspectMode(rawValue: parts[0]) ?? .full
                    let filter = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                    if let rsp = try? InspectControl.transact(bundleID: bid, op: .uiTree,
                                                              mode: mode, filter: filter),
                       let tree = rsp.tree,
                       let data = try? JSONEncoder().encode(tree) {
                        freshHashes[walk] = SnapshotStore.hash(data)
                    } else {
                        freshHashes[walk] = nil
                    }
                }
            }
            let dicts: [[String: Any]] = page.map { b in
                var stale = false
                var reason: String? = nil
                if b.target.kind == "element" {
                    if let ref = b.snapshotRef,
                       let man = SnapshotStore.load(bundleID: bid, id: ref) {
                        if man.mode != (b.target.mode ?? "full") {
                            stale = true; reason = "mode-changed"
                        } else if checkFresh {
                            let walk = "\(man.mode)|\(man.filter ?? "")"
                            if let fresh = freshHashes[walk] {
                                if fresh != man.treeHash { stale = true; reason = "tree-changed" }
                            } else {
                                stale = true; reason = "check-failed"
                            }
                        }
                    } else {
                        stale = true; reason = "snapshot-gone"
                    }
                }
                return bookmarkDict(b, stale: stale, staleReason: reason)
            }
            return MCPServer.toolResult(id, ["bundleID": bid, "count": dicts.count,
                                   "total": list.count, "bookmarks": dicts,
                                   "groups": store.groups.map { groupDict($0) }])

        case "bookmark_remove":
            guard let ids = args["ids"] as? [String], !ids.isEmpty else {
                throw ToolRouter.bail("bookmark_remove needs ids")
            }
            for x in ids where !(x.hasPrefix("bm_") || x.hasPrefix("grp_")) {
                throw ToolRouter.bail("unknown id '\(x)' - bookmarks are bm_*, groups are grp_*")
            }
            let before = BookmarkStore.load(bundleID: bid)
            let bmGone = Set(ids.filter { $0.hasPrefix("bm_") })
                .intersection(before.bookmarks.map(\.id))
            let grpGone = Set(ids.filter { $0.hasPrefix("grp_") })
                .intersection(before.groups.map(\.id))
            let missing = ids.filter { !bmGone.contains($0) && !grpGone.contains($0) }
            if isDryRun(args) {
                return MCPServer.toolResult(id, ["dryRun": true, "bundleID": bid,
                                       "wouldRemoveBookmarks": Array(bmGone).sorted(),
                                       "wouldRemoveGroups": Array(grpGone).sorted(),
                                       "missing": missing])
            }
            BookmarkStore.modify(bundleID: bid) { store in
                store.bookmarks.removeAll(where: { bmGone.contains($0.id) })
                store.groups.removeAll(where: { grpGone.contains($0.id) })
                // Membership follows the bookmark: no dangling ids in surviving groups.
                // Surviving groups keep surviving members; unpinned snapshots become
                // sweepable at the next launch (the sweep owns deletion, not this call).
                for i in store.groups.indices {
                    store.groups[i].bookmarkIds.removeAll(where: { bmGone.contains($0) })
                }
            }
            return MCPServer.toolResult(id, ["bundleID": bid,
                                   "removedBookmarks": Array(bmGone).sorted(),
                                   "removedGroups": Array(grpGone).sorted(),
                                   "missing": missing])

        default:
            throw ToolRouter.bail("unknown inspect tool: \(name)")
        }
    }

    /// One plain uiTree transaction pinned as a timeline entry. No new op, no guest change:
    /// the guest cannot tell this read from a normal uitree_read.
    static func captureTreeSnapshot(_ bid: String, trigger: String, op: String,
                                     mode: InspectMode, redacted: Bool,
                                     elementId: String? = nil,
                                     x: Double? = nil, y: Double? = nil,
                                     x1: Double? = nil, y1: Double? = nil,
                                     x2: Double? = nil, y2: Double? = nil,
                                     steps: Int? = nil, textLength: Int? = nil)
    throws -> SnapshotManifest {
        let rsp = try InspectControl.transact(bundleID: bid, op: .uiTree, mode: mode)
        guard let tree = rsp.tree,
              let treeData = try? JSONEncoder().encode(tree) else {
            throw ToolRouter.bail("snapshot read returned an undecodable tree for \(bid)")
        }
        return SnapshotStore.capture(
            bundleID: bid, trigger: trigger,
            opRef: SnapshotOpRef(op: op, elementId: elementId, x: x, y: y,
                                 x1: x1, y1: y1, x2: x2, y2: y2,
                                 steps: steps, textLength: textLength),
            mode: mode, filter: nil, redacted: redacted,
            truncated: rsp.truncated ?? false, tree: tree, treeBytes: treeData)
    }

    /// Manifest without the tree: listings carry metadata, trees stay on disk until a diff.
    static func manifestSummary(_ m: SnapshotManifest) -> [String: Any] {
        var d: [String: Any] = [
            "id": m.id, "bundleID": m.bundleID, "capturedAt": m.capturedAt,
            "epochMs": m.epochMs, "trigger": m.trigger, "mode": m.mode,
            "redacted": m.redacted, "truncated": m.truncated,
            "nodes": m.nodes, "treeHash": m.treeHash]
        if let filter = m.filter { d["filter"] = filter }
        if let rootId = m.rootId { d["rootId"] = rootId }
        d["depthLimit"] = m.depthLimit
        d["nodeLimit"] = m.nodeLimit
        if let shotFile = m.shotFile { d["shotFile"] = shotFile }
        if let w = m.width { d["width"] = w }
        if let h = m.height { d["height"] = h }
        return d
    }

    /// Resolve a group ref (id or name), creating by name when absent. Returns the group id.
    /// Creation-on-reference keeps filing a one-call act; pure renames go through
    /// bookmark_note.
    static func resolveBookmarkGroup(in store: inout BookmarkStoreData, ref: String) -> String {
        if let g = store.groups.first(where: { $0.id == ref || $0.name == ref }) { return g.id }
        let g = BookmarkGroup(id: BookmarkStore.mintID("grp_"), name: ref, note: nil,
                              bookmarkIds: [], createdAt: BookmarkStore.stamp(),
                              updatedAt: BookmarkStore.stamp())
        store.groups.append(g)
        return g.id
    }

    /// Destructive tools preview by default (OLD safety contract): pass
    /// dryRun:false to execute. Omitted dryRun previews; nothing is deleted.
    static func isDryRun(_ args: [String: Any]) -> Bool { (args["dryRun"] as? Bool) ?? true }

    /// Read-only twin for dry-runs: reports whether the call would create the group.
    static func peekBookmarkGroup(in store: BookmarkStoreData, ref: String)
    -> (id: String, name: String, created: Bool) {
        if let g = store.groups.first(where: { $0.id == ref || $0.name == ref }) {
            return (g.id, g.name, false)
        }
        return (BookmarkStore.mintID("grp_"), ref, true)
    }

    static func bookmarkDict(_ b: AgentBookmark, stale: Bool, staleReason: String?)
    -> [String: Any] {
        var t: [String: Any] = ["kind": b.target.kind]
        if let v = b.target.className { t["className"] = v }
        if let v = b.target.symbol { t["symbol"] = v }
        if let v = b.target.elementId { t["elementId"] = v }
        if let v = b.target.mode { t["mode"] = v }
        if let v = b.target.role { t["role"] = v }
        if let v = b.target.frame { t["frame"] = v }
        if let v = b.target.axLabel { t["axLabel"] = v }
        if let v = b.target.viewController { t["viewController"] = v }
        if let v = b.target.superclasses { t["superclasses"] = v }
        var d: [String: Any] = ["id": b.id, "bundleID": b.bundleID, "target": t,
                                "tags": b.tags, "createdAt": b.createdAt,
                                "updatedAt": b.updatedAt, "stale": stale]
        if let c = b.comment { d["comment"] = c }
        if let s = b.snapshotRef { d["snapshotRef"] = s }
        if let r = staleReason { d["staleReason"] = r }
        return d
    }

    static func groupDict(_ g: BookmarkGroup) -> [String: Any] {
        var d: [String: Any] = ["id": g.id, "name": g.name,
                                "members": g.bookmarkIds,
                                "createdAt": g.createdAt, "updatedAt": g.updatedAt]
        if let n = g.note { d["note"] = n }
        return d
    }

    /// Host-side mirror of the guest ceilings (Inspector.maxDepth/maxNodes - the guest
    /// file does not compile into this target, so the numbers are stated once here).
    /// The guest clamps incoming caps to these and never raises; the tool layer bails
    /// out-of-range before anything crosses the wire.
    enum InspectCaps {
        static let depth = 24
        static let nodes = 2000
    }

    /// Agent-narrowable tree caps, validated in the steps/limit vocabulary. Omitted means
    /// the historic defaults. Ints ride through; whole-number Doubles (JSON's only number
    /// shape) coerce, like tap's x/y.
    static func treeCaps(_ args: [String: Any]) throws -> (depth: Int?, nodes: Int?) {
        func cap(_ key: String, _ hi: Int) throws -> Int? {
            guard let raw = args[key] else { return nil }
            guard let v = (raw as? Int) ?? (raw as? Double).map(Int.init) else {
                throw ToolRouter.bail("\(key) must be an integer 1...\(hi)")
            }
            guard (1...hi).contains(v) else { throw ToolRouter.bail("\(key) must be 1...\(hi)") }
            return v
        }
        return (try cap("depthLimit", InspectCaps.depth),
                try cap("nodeLimit", InspectCaps.nodes))
    }

    /// Tree mode shared by every elementId-taking tool: ids only resolve in the mode whose
    /// walk produced them, so the mode rides along and defaults to full, never guessed.
    static func inspectMode(_ args: [String: Any]) throws -> InspectMode {
        guard let raw = args["mode"] as? String else { return .full }
        guard let mode = InspectMode(rawValue: raw) else {
            throw ToolRouter.bail("mode must be full or compact, got '\(raw)'")
        }
        return mode
    }

    /// The inspect-tool name set, kept next to the catalog it routes to. The
    /// dispatcher forks on this (never its own copy) so the two cannot drift.
    static let inspectToolNames: Set<String> = [
        "uitree_read", "screenshot", "tap_element", "swipe", "set_text",
        "inspect_classes", "inspect_element", "inspect_class_detail",
        "inspect_snapshot", "inspect_timeline", "inspect_diff",
        "inspect_clear_snapshots",
        "bookmark_add", "bookmark_note", "bookmark_move",
        "bookmark_list", "bookmark_remove",
    ]

    /// Live-first class inventory: live runtime classes when Agent Mode runs,
    /// static strings otherwise (ObjC classes invisible statically - stated).
    static func classInventory(_ bundleID: String, filter: String?, limit: Int) throws -> [String: Any] {
        let liveAllowed = (try? InspectGate.requireLive(bundleID: bundleID)) != nil
        var liveClasses: [String]? = nil
        var liveTotal = 0
        var liveError: String? = nil
        if liveAllowed {
            do {
                let rsp = try InspectControl.transact(bundleID: bundleID, op: .classes,
                                                      filter: filter, limit: limit)
                liveClasses = rsp.classes ?? []
                liveTotal = rsp.totalCount ?? liveClasses?.count ?? 0
            } catch let e as ToolRouter.ToolError {
                liveError = e.message
            }
        }
        let (exePath, staticClasses, staticSelectors) = try ReportBuilder.staticClassInventory(
            bundleID, filter: filter, limit: limit)
        let classes: [String] = liveClasses ?? staticClasses
        var payload: [String: Any] = [
            "bundleID": bundleID,
            "executable": exePath,
            "filter": filter ?? NSNull(),
            "source": liveClasses == nil ? "binary" : "live",
            "classes": Array(classes.prefix(limit)),
            "selectors": Array(staticSelectors.prefix(limit)),
            "classCount": classes.count,
            "selectorCount": staticSelectors.count
        ]
        if liveClasses != nil {
            payload["totalLoaded"] = liveTotal
            payload["note"] = "classes from the loaded runtime (includes generated classes); selectors from static binary strings"
        } else {
            payload["note"] = "static binary strings only: misses generated classes and plain ObjC classes - launch with Agent Mode for the live list"
        }
        if let liveError { payload["liveError"] = liveError }
        return payload
    }
}
