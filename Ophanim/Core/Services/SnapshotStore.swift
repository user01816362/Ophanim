//
//  SnapshotStore.swift
//  Ophanim
//
//  Host-side UI-snapshot timeline for Inspect Agent Mode. A snapshot pins one uitree read
//  (+ optional screenshot sidecar) with a timestamp and trigger, so an agent can capture
//  real-time rebuild behavior - e.g. a search bar flipping UISearchBarTextField ->
//  SearchBarTextFieldV2 -> back across scrolls - and diff consecutive captures for named
//  flip events instead of eyeballing two 40KB trees.
//
//  Host-side only: snapshots compose existing uiTree/screenshot transactions, so the guest
//  cannot tell a snapshot read from a normal read. No engine change, no protocol change.
//
//  Retention mirrors LogStore: keep newest 20 (10 pre/post hand-op pairs), auto-prune
//  oldest-first on capture, manual clear with dryRun at the tool layer. Placement is a
//  `snapshots/` subdir of the canonical log dir: uninstall already removes the whole
//  Logs/<bid> tree, and every existing enumeration (runFiles, events, clear_logs,
//  sweepOrphans) is non-recursive and name/extension-filtered, so `snap-*` stems cannot
//  collide with `run-*`, `inspect-cmd.json`, or `inspect-rsp-*` slot files.
//

import Foundation
import CryptoKit

extension Notification.Name {
    /// Posted after inspect_clear_snapshots deletes an app's timeline, so any GUI timeline
    /// view resets instead of showing removed snapshots. Object carries the bundle id.
    /// (Provisional: no GUI observer exists yet; the LogStore precedent keeps the contract.)
    static let ophanimSnapshotsCleared = Notification.Name("be.ophanim.Ophanim.snapshotsCleared")
}

/// Reference to the hand op a pre/post snapshot brackets. Never carries setText text -
/// only its length: snapshot files are retained history, not a keystroke log.
struct SnapshotOpRef: Codable {
    var op: String
    var elementId: String?
    var x: Double?
    var y: Double?
    var x1: Double?
    var y1: Double?
    var x2: Double?
    var y2: Double?
    var steps: Int?
    var textLength: Int?
}

/// One timeline entry: manifest metadata + the tree inline (already sized for the MCP text
/// pipe). Filenames sort chronologically: snap-<UTC stamp>-<seq>.json.
struct SnapshotManifest: Codable {
    var id: String
    var bundleID: String
    var capturedAt: String
    var epochMs: Int64
    var trigger: String
    var opRef: SnapshotOpRef?
    var mode: String
    var filter: String?
    /// Subtree root this snapshot was read from (nil = whole forest). Diffs only pair
    /// equal roots. Default nil decodes pre-root manifests, so old timelines keep reading.
    var rootId: String? = nil
    /// Caps the walk ran under (defaults = historic ceilings, so pre-cap manifests decode
    /// and pair with full-default reads). Diffs only pair equal caps.
    var depthLimit: Int = 24
    var nodeLimit: Int = 2000
    /// Redaction state at capture, inherited from settings. Stored snapshots never change
    /// state: reading with redaction later disabled must not unmask stored trees/JPEGs.
    var redacted: Bool
    var truncated: Bool
    /// Which caps cut this read (nil/empty = uncut or pre-cap manifest). Informational:
    /// pairing keys on caps, not on this list.
    var truncatedBy: [String]? = nil
    /// Key-window scene at capture (nil = pre-scene manifest). Diffs only pair equal
    /// scenes, so cross-window pairs refuse stated instead of mixing windows silently.
    var scene: String? = nil
    /// Instance-proven frameworks owning pixels at capture (nil = pre-framework
    /// manifest or indistinguishable UIKit). Informational: never a pairing key.
    var frameworks: [String]? = nil
    /// View controllers owning walked pixels (union, ordered). Informational:
    /// answers which screens a snapshot spans without re-reading the tree.
    var vcs: [String]? = nil
    var nodes: Int
    var treeHash: String
    var shotFile: String?
    var width: Int?
    var height: Int?
    var tree: InspectNode
}

enum SnapshotStore {
    static let keepSnapshots = 20

    /// Snapshot timeline directory (created on demand).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The `snapshots/` directory URL.
    static func snapshotsDir(bundleID: String) -> URL {
        let dir = OPPaths.logDirectory(forBundleID: bundleID)
            .appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write one snapshot (manifest + optional JPEG sidecar), prune beyond keep, return
    /// the manifest. Filenames are lexical-chronological; same-second captures bump seq.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter trigger: The trigger name (`pre-*`/`post-*`/manual).
    /// - Parameter opRef: The bracketed hand op (nil for manual reads).
    /// - Parameter mode: The tree mode.
    /// - Parameter filter: The tree substring filter, if any.
    /// - Parameter rootId: The subtree root, if any.
    /// - Parameter depthLimit: The tree depth cap.
    /// - Parameter nodeLimit: The tree node cap.
    /// - Parameter redacted: The effective redaction flag (frozen on the snapshot).
    /// - Parameter truncated: Whether the tree hit a cap.
    /// - Parameter truncatedBy: Which caps truncated the tree.
    /// - Parameter scene: The scene identifier, if reported.
    /// - Parameter frameworks: The detected frameworks, if reported.
    /// - Parameter vcs: The view controllers, if reported.
    /// - Parameter tree: The captured tree.
    /// - Parameter treeBytes: The encoded tree (hashed for `treeHash`).
    /// - Parameter jpeg: Optional screenshot bytes (sidecar).
    /// - Parameter width: Optional screenshot width.
    /// - Parameter height: Optional screenshot height.
    /// - Returns: The written manifest.
    static func capture(bundleID: String, trigger: String, opRef: SnapshotOpRef?,
                        mode: InspectMode, filter: String?, rootId: String? = nil,
                        depthLimit: Int = 24, nodeLimit: Int = 2000,
                        redacted: Bool,
                        truncated: Bool, truncatedBy: [String]? = nil,
                        scene: String? = nil, frameworks: [String]? = nil,
                        vcs: [String]? = nil,
                        tree: InspectNode, treeBytes: Data,
                        jpeg: Data? = nil, width: Int? = nil, height: Int? = nil) -> SnapshotManifest {
        let dir = snapshotsDir(bundleID: bundleID)
        let now = Date()
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: now)
        }()
        var seq = 0
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        while existing.contains(where: {
            $0.lastPathComponent == "snap-\(stamp)-\(String(format: "%02d", seq)).json"
        }) { seq += 1 }
        let id = "\(stamp)-\(String(format: "%02d", seq))"
        let iso = ISO8601DateFormatter().string(from: now)
        var shotFile: String? = nil
        if let jpeg {
            shotFile = "snap-\(id).jpg"
            try? jpeg.write(to: dir.appendingPathComponent(shotFile!),
                            options: .atomic)
        }
        let manifest = SnapshotManifest(
            id: id, bundleID: bundleID, capturedAt: iso,
            epochMs: Int64(now.timeIntervalSince1970 * 1000),
            trigger: trigger, opRef: opRef, mode: mode.rawValue, filter: filter,
            rootId: rootId, depthLimit: depthLimit, nodeLimit: nodeLimit,
            redacted: redacted, truncated: truncated, truncatedBy: truncatedBy,
            scene: scene, frameworks: frameworks, vcs: vcs,
            nodes: nodeCount(tree), treeHash: hash(treeBytes),
            shotFile: shotFile, width: width, height: height, tree: tree)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: dir.appendingPathComponent("snap-\(id).json"),
                            options: .atomic)
        }
        prune(bundleID: bundleID, keep: keepSnapshots)
        return manifest
    }

    /// Manifests oldest-first (filenames sort chronologically). Trees included: callers
    /// that only list strip them.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The manifests, oldest first (corrupt files skipped).
    static func list(bundleID: String) -> [SnapshotManifest] {
        let dir = snapshotsDir(bundleID: bundleID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let files = entries
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.hasPrefix("snap-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [SnapshotManifest] = []
        for f in files {
            guard let data = try? Data(contentsOf: f),
                  let man = try? JSONDecoder().decode(SnapshotManifest.self, from: data) else { continue }
            out.append(man)
        }
        return out
    }

    /// Loads one snapshot manifest by id.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter id: The snapshot id.
    /// - Returns: The manifest, or nil when missing/corrupt.
    static func load(bundleID: String, id: String) -> SnapshotManifest? {
        let url = snapshotsDir(bundleID: bundleID)
            .appendingPathComponent("snap-\(id).json")
        guard let data = try? Data(contentsOf: url),
              let man = try? JSONDecoder().decode(SnapshotManifest.self, from: data) else { return nil }
        return man
    }

    /// Oldest-first eviction of whole stems (.json + .jpg), keeping the newest `keep`
    /// UNPINNED snapshots plus every pinned one. Pinned entries are explicit agent intent
    /// (kept for later analysis across launches); their count is bounded at pin time by
    /// BookmarkStore.maxPins, so sparing them cannot grow the timeline without bound.
    /// Host-side files only, same ordering-not-locking rationale as LogStore: capture runs
    /// when no guest writer holds these files (the guest never writes them at all).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Parameter keep: How many newest unpinned snapshots survive.
    static func prune(bundleID: String, keep: Int = keepSnapshots) {
        let dir = snapshotsDir(bundleID: bundleID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        let pinned = BookmarkStore.snapshotRefs(bundleID: bundleID)
        let manifests = entries
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.hasPrefix("snap-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let evictable = manifests.filter {
            !pinned.contains(stemID($0))
        }
        guard evictable.count > keep else { return }
        for stale in evictable.dropLast(keep) {
            let stem = stale.deletingPathExtension().lastPathComponent
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(stem + ".jpg"))
        }
    }

    /// Launch sweep: snapshots describe the previous run's UI, so a new launch starts
    /// clean - except entries the agent pinned via bookmarks, which survive for later
    /// analysis. Host-side files the guest never writes: no live-writer hazard, so no
    /// running guard is needed (unlike the pre-stamp log sweep, which can orphan a writer).
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    static func sweepUnpinned(bundleID: String) {
        let pinned = BookmarkStore.snapshotRefs(bundleID: bundleID)
        let (files, _) = inventory(bundleID: bundleID)
        for f in files {
            guard f.pathExtension == "json" else { continue } // sidecars go with stems
            guard !pinned.contains(stemID(f)) else { continue }
            try? FileManager.default.removeItem(at: f)
            try? FileManager.default.removeItem(
                at: f.deletingPathExtension().appendingPathExtension("jpg"))
        }
    }

    /// snap-<id>.json -> <id>.
    ///
    /// - Parameter url: The snapshot file URL.
    /// - Returns: The snapshot id.
    static func stemID(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.hasPrefix("snap-") ? String(stem.dropFirst(5)) : stem
    }

    /// Timeline file inventory (manifests + sidecars) with total bytes.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The `snap-*` files (sorted) and their total bytes.
    static func inventory(bundleID: String) -> (files: [URL], bytes: UInt64) {
        let dir = snapshotsDir(bundleID: bundleID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return ([], 0) }
        let files = entries.filter {
            let stem = $0.deletingPathExtension().lastPathComponent
            return stem.hasPrefix("snap-")
                && ($0.pathExtension == "json" || $0.pathExtension == "jpg")
        }
        var bytes: UInt64 = 0
        for f in files {
            bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                .map(UInt64.init) ?? 0
        }
        return (files.sorted { $0.lastPathComponent < $1.lastPathComponent }, bytes)
    }

    /// Delete the whole timeline. Returns removed count + bytes. Posts the reset
    /// notification so future GUI views drop removed snapshots instead of showing them.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: The removed file count and the inventoried bytes.
    @discardableResult
    static func clear(bundleID: String) -> (removed: Int, bytes: UInt64) {
        let (files, bytes) = inventory(bundleID: bundleID)
        var removed = 0
        for f in files {
            if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
        }
        if removed > 0 {
            NotificationCenter.default.post(name: .ophanimSnapshotsCleared, object: bundleID)
        }
        return (removed, bytes)
    }

    /// Node count including the node itself.
    ///
    /// - Parameter node: The tree to count.
    /// - Returns: The total node count.
    static func nodeCount(_ node: InspectNode) -> Int {
        node.children.reduce(1) { $0 + nodeCount($1) }
    }

    /// SHA-256 hex of bytes (tree identity for change detection).
    ///
    /// - Parameter bytes: The bytes to hash.
    /// - Returns: The lowercase hex digest.
    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Diff

    /// Flattened node for keying. Key = (role, rounded frame, axIdentifier): positional ids
    /// are unstable across rebuilds, so keying on id reports every rebuild as add+remove
    /// noise. Size participates; origin is normalized away when a scroll is detected.
    struct FlatNode {
        var path: String
        var cls: String
        var role: String
        var frame: [Double]
        var text: String?
        var secure: Bool
        var axIdentifier: String?
        var layer: String?
    }

    /// Flattened node for keying. Path is the guest's positional id verbatim ("0.2.1"):
    /// ids are already full paths from the window root (Inspector assigns "0", then
    /// "0.2.1" downward), so joining parent + child would duplicate every segment into
    /// "root.0.0.0..." noise. Diff paths double as resolvable element ids.
    static func flatten(_ node: InspectNode, out: inout [FlatNode]) {
        out.append(FlatNode(path: node.id, cls: node.cls, role: node.role, frame: node.frame,
                            text: node.text, secure: node.secure,
                            axIdentifier: node.axIdentifier, layer: node.layer))
        for c in node.children { flatten(c, out: &out) }
    }

    static func key(_ n: FlatNode, dx: Double = 0, dy: Double = 0) -> String {
        let r: (Double) -> String = { String(format: "%.1f", ($0 * 10).rounded() / 10) }
        let x = ox(n) - dx
        let y = oy(n) - dy
        let w = n.frame.count > 2 ? n.frame[2] : 0
        let h = n.frame.count > 3 ? n.frame[3] : 0
        return "\(n.role)|\(r(x)),\(r(y)),\(r(w)),\(r(h))|\(n.axIdentifier ?? "")"
    }

    /// Coarse key ignoring origin (and class): finds scroll translation first, since
    /// scrolled nodes share no exact key with their pre-scroll selves. A class flip keeps
    /// its coarse key (same role/size), so flips never blind scroll detection.
    static func coarseKey(_ n: FlatNode) -> String {
        let r: (Double) -> String = { String(format: "%.1f", ($0 * 10).rounded() / 10) }
        let w = n.frame.count > 2 ? n.frame[2] : 0
        let h = n.frame.count > 3 ? n.frame[3] : 0
        return "\(n.role)|\(r(w)),\(r(h))|\(n.axIdentifier ?? "")"
    }

    static func ox(_ n: FlatNode) -> Double { n.frame.count > 0 ? n.frame[0] : 0 }
    static func oy(_ n: FlatNode) -> Double { n.frame.count > 1 ? n.frame[1] : 0 }

    /// Diff two snapshots into named events. Returns (events, partial, reason).
    /// Secure node text is never emitted - only `secure:true`.
    ///
    /// - Parameter a: The older snapshot.
    /// - Parameter b: The newer snapshot.
    /// - Returns: The named flip events, whether the diff is partial, and why.
    static func diff(from a: SnapshotManifest, to b: SnapshotManifest)
    -> (events: [[String: Any]], partial: Bool, reason: String?) {
        var events: [[String: Any]] = []
        var flatA: [FlatNode] = [], flatB: [FlatNode] = []
        flatten(a.tree, out: &flatA)
        flatten(b.tree, out: &flatB)

        // Scroll-suppression pass: coarse-match ignoring origin, so a real scroll (where
        // nothing shares an exact key) still yields its uniform translation. A supermajority
        // sharing one (dx, dy) means the list scrolled: record it and re-key the fine pass
        // with origins normalized, so scrolling does not report as add+remove noise.
        var coarseA: [String: [FlatNode]] = [:]
        for n in flatA { coarseA[coarseKey(n), default: []].append(n) }
        var coarseB: [String: [FlatNode]] = [:]
        for n in flatB { coarseB[coarseKey(n), default: []].append(n) }
        var deltas: [[Double]: Int] = [:]
        var matched = 0
        // Per-node coarse delta, so the fine pass normalizes only nodes that actually
        // scrolled: chrome (window, nav bars) sits at delta 0 and keeps exact keys.
        var bDelta: [String: [Double]] = [:]
        for (k, bs) in coarseB {
            guard let aus = coarseA[k] else { continue }
            for (m, n) in zip(aus, bs) {
                matched += 1
                let d = [round1(ox(n) - ox(m)), round1(oy(n) - oy(m))]
                deltas[d, default: 0] += 1
                bDelta[n.path] = d
            }
        }
        var dx = 0.0, dy = 0.0
        if let (d, c) = deltas.max(by: { $0.value < $1.value }),
           matched >= 3, Double(c) >= Double(matched) * 0.6,
           (d[0] != 0 || d[1] != 0) {
            dx = d[0]; dy = d[1]
            events.append(["event": "scroll", "dx": dx, "dy": dy, "nodes": c])
        }
        let scrolling = dx != 0 || dy != 0

        var normA: [String: FlatNode] = [:]
        for n in flatA { normA[key(n)] = n }
        var normB: [String: FlatNode] = [:]
        for n in flatB {
            // Normalize only scroll participants; everything else keeps its exact key.
            let d = bDelta[n.path] ?? [0.0, 0.0]
            let shift = scrolling && d == [dx, dy]
            normB[key(n, dx: shift ? dx : 0, dy: shift ? dy : 0)] = n
        }

        // Flip pass: same key, different but related class = rebuild (the search-bar
        // flip). Same key, same class, different text = content change (secure text never
        // emitted). Same slot but unrelated classes = a replacement: counted as add+remove,
        // not a flip (relatedness = shared substring of 5+, so SearchBarTextField->V2 flips
        // while OldAdView->NewPromoView does not).
        var flips = 0, added = 0, removed = 0
        var addedSamples: [String] = [], removedSamples: [String] = []
        var changedPaths: [String] = []
        var replacedA: Set<String> = []
        for (k, nb) in normB {
            guard let na = normA[k] else {
                added += 1
                if addedSamples.count < 10 { addedSamples.append("\(nb.cls)@\(nb.path)") }
                changedPaths.append(nb.path)
                continue
            }
            if na.cls != nb.cls {
                if classSimilar(na.cls, nb.cls) {
                    flips += 1
                    changedPaths.append(nb.path)
                    events.append(["event": "class_flip", "key": k,
                                   "from": na.cls, "to": nb.cls, "path": nb.path])
                } else {
                    added += 1
                    if addedSamples.count < 10 { addedSamples.append("\(nb.cls)@\(nb.path)") }
                    replacedA.insert(k)
                    changedPaths.append(nb.path)
                }
            } else if na.layer != nil && nb.layer != nil && na.layer != nb.layer {
                // Same slot, same class, different backing layer (video started, transform
                // layer swapped): sibling to class_flip. Both-nil (old timelines) never fires.
                changedPaths.append(nb.path)
                events.append(["event": "layer_flip", "key": k,
                               "from": na.layer ?? "", "to": nb.layer ?? "", "path": nb.path])
            } else if na.text != nb.text {
                changedPaths.append(nb.path)
                if nb.secure {
                    events.append(["event": "content_change", "key": k,
                                   "cls": nb.cls, "secure": true])
                } else {
                    events.append(["event": "content_change", "key": k,
                                   "cls": nb.cls, "from": na.text ?? "", "to": nb.text ?? ""])
                }
            }
        }
        for (k, na) in normA where normB[k] == nil || replacedA.contains(k) {
            removed += 1
            if removedSamples.count < 10 { removedSamples.append("\(na.cls)@\(na.path)") }
            changedPaths.append(na.path)
        }
        // Fold a flip burst + add/remove cluster into one subtree_rebuild naming the
        // lowest common ancestor path, so a nav-bar rebuild reads as one event.
        if flips > 0 && added + removed > 5 {
            events.append(["event": "subtree_rebuild",
                           "ancestor": commonAncestor(changedPaths),
                           "flips": flips, "added": added, "removed": removed])
        } else {
            if added > 0 { events.append(["event": "nodes_added", "count": added, "sample": addedSamples]) }
            if removed > 0 { events.append(["event": "nodes_removed", "count": removed, "sample": removedSamples]) }
        }
        events.append(["event": "count_delta",
                       "from": flatA.count, "to": flatB.count, "delta": flatB.count - flatA.count])

        var partial = false
        var reasons: [String] = []
        if a.truncated || b.truncated {
            partial = true
            reasons.append("a budget-cut tree is partial input")
        }
        if a.redacted != b.redacted {
            partial = true
            reasons.append("redaction state differs; text is unreliable, classes still comparable")
        }
        return (events, partial, partial ? reasons.joined(separator: "; ") : nil)
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// Related rebuild or unrelated replacement? Longest common substring of 5+ characters
    /// (case-sensitive): versioned rebuilds share their stem (SearchBarTextField), while a
    /// different view in the same slot does not (OldAdView vs NewPromoView share "View").
    /// Heuristic, stated as such in inspect_diff output by emitting add+remove instead.
    static func classSimilar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty && !y.isEmpty else { return false }
        var best = 0
        var dp = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var prev = 0
            for j in 1...y.count {
                let t = dp[j]
                if x[i - 1] == y[j - 1] { dp[j] = prev + 1; best = max(best, dp[j]) } else { dp[j] = 0 }
                prev = t
            }
        }
        return best >= 5
    }

    /// Longest common dot-prefix of index paths ("0.0.0.0.1" & "0.0.0.0.2" -> "0.0.0.0").
    static func commonAncestor(_ paths: [String]) -> String {
        guard var prefix = paths.first?.split(separator: ".").map(String.init),
              !prefix.isEmpty else { return "" }
        for p in paths.dropFirst() {
            let parts = p.split(separator: ".").map(String.init)
            var i = 0
            while i < prefix.count && i < parts.count && prefix[i] == parts[i] { i += 1 }
            prefix = Array(prefix.prefix(i))
            if prefix.isEmpty { break }
        }
        return prefix.joined(separator: ".")
    }
}
