//
//  InspectRequest.swift
//  Galgal
//
//  InspectProtocol command/response payloads. The host (Ophanim/MCP) writes a command file,
//  the in-process pump answers with the matching response file; both live in the log
//  directory both sides already share (OPPaths.logDirectory), so no new channel, no new
//  entitlement, no TCC prompt. Single-slot protocol: one command at a time per app.
//

import Foundation

/// What the AI operator can ask the hosted app to do: tree (see), shot (see pixels),
/// tap/swipe (touch), setText (type), classes (runtime class list), element (single-view
/// detail), classDetail (runtime method/ivar inventory for hook targeting). These cover
/// observe-orient-act for a touchscreen UI; anything finer
/// (multi-touch, gestures) stays out by design.
enum InspectOp: String, Codable {
    case uiTree
    case screenshot
    case tap
    case swipe
    case setText
    case classes
    case element
    case classDetail
    /// Geometric pick: frontmost view at normalized x/y (hitTest-independent, so
    /// interaction-disabled views resolve). Returns elementId + class + VC.
    case pick
}

/// Tree density. `full` walks everything (positional ids over the raw hierarchy, deepest).
/// `compact` collapses layout-only single-child containers (plain UIViews with no text,
/// identifier, or control of their own), which is where UIKit's 20-deep chains come from.
/// Absent mode decodes as full: old hosts keep working, new hosts ask compact.
enum InspectMode: String, Codable {
    case full
    case compact
}

/// Host -> guest. All fields optional except id/op: each op reads what it needs and fails
/// stated on the rest. Additive-only evolution: new fields default, old hosts unaffected.
struct InspectCommand: Codable {
    var id: String
    var op: InspectOp
    /// Tree mode for uiTree, and the mode tap/setText resolve elementIds against. Element ids
    /// only mean something in the mode whose walk produced them - mixing modes fails stated.
    var mode: InspectMode?
    /// uiTree only: case-insensitive substring kept (matched against text, class, ax label);
    /// ancestors of matches are kept so hits stay reachable, everything else is pruned.
    var filter: String?
    /// tap/setText/element: elementId ("0.2.1" index path from uiTree) preferred.
    /// uiTree: doubles as the subtree walk root (see rootId on the tool side).
    var elementId: String?
    /// tap: normalized x/y fallback in 0...1.
    var x: Double?
    var y: Double?
    /// swipe: normalized start/end in 0...1.
    var x1: Double?
    var y1: Double?
    var x2: Double?
    var y2: Double?
    /// swipe: interpolation steps, clamped 1...20 (default 8).
    var steps: Int?
    /// uiTree: agent-narrowable caps. Narrow-only: the guest clamps each to its hard
    /// ceiling (depth 24, nodes 2000); omitted means the historic defaults.
    /// Additive optional - old hosts never send them, old guests never read them.
    var depthLimit: Int?
    var nodeLimit: Int?
    /// classes: max names returned (default 200, hard cap 2000).
    var limit: Int?
    /// classDetail: class name to inventory (methods/ivars/properties/protocols).
    var className: String?
    /// setText: replacement text for a field.
    var text: String?
}

/// Guest -> host. Payload shapes are op-specific JSON values, kept intentionally loose so a
/// newer guest can add fields without breaking an older host (unknown keys are ignored).
struct InspectResponse: Codable {
    var id: String
    var ok: Bool
    var error: String?
    /// Tree reads only: true when depth/node budgets cut content (see Inspector caps).
    var truncated: Bool?
    /// Which caps cut, when truncated is true: any of "depth", "nodes". Omitted on legacy
    /// responses (truncated bool only) and when nothing cut. Additive optional.
    var truncatedBy: [String]?
    var tree: InspectNode?
    var imageBase64: String?
    var mimeType: String?
    var width: Int?
    var height: Int?
    var acted: Bool?
    var targetClass: String?
    /// element: superclass chain (nearest first) + owning view controller (responder chain).
    var superclasses: [String]? = nil
    /// Owning view controller (responder chain) for element ops, if any.
    var viewController: String? = nil
    /// classes: matched names + total loaded (before filter).
    var classes: [String]? = nil
    var totalCount: Int? = nil
    /// classDetail: method/ivar inventory for hook targeting (nil for other ops).
    var classDetail: InspectClassDetail? = nil
    /// uiTree/screenshot: frameworks owning pixels, instance-proven in the walked tree
    /// (nil/empty = indistinguishable UIKit). Values: uikit-objc, uikit-swift, swiftui,
    /// react-native, flutter, unity, capacitor, cordova, xamarin.
    var frameworksDetected: [String]? = nil
    /// framework -> up to 5 matched class/VC names, so operators can audit the claim.
    var frameworkEvidence: [String: [String]]? = nil
    /// uiTree only: react-native arch from sentinel presence (paper/fabric/both/unknown).
    var rnArch: String? = nil
    /// Key-window scene at capture ("<sceneId>:level<n>:key"), so diffs can refuse
    /// cross-scene pairs stated instead of mixing windows silently.
    var scene: String? = nil
    /// View controllers owning walked pixels (union, ordered), so operators know
    /// which screens a tree spans without per-node reads.
    var vcs: [String]? = nil
    /// pick: positional id of the frontmost view at the point (same-mode resolvable).
    var elementId: String? = nil

    static func failure(id: String, _ message: String) -> InspectResponse {
        InspectResponse(id: id, ok: false, error: message, truncated: nil, truncatedBy: nil, tree: nil, imageBase64: nil,
                        mimeType: nil, width: nil, height: nil, acted: nil, targetClass: nil)
    }
}

/// One method on a class: selector, EXPLICIT arg count (self/_cmd excluded - the number
/// set_objc_hooks takes), and the return type's first encoding code.
struct InspectMethodInfo: Codable {
    var sel: String
    var args: Int
    var ret: String
}

/// One ivar: name + first type-encoding code (full struct layouts stay out - counts and
/// hooks need names, not offsets).
struct InspectIvarInfo: Codable {
    var name: String
    var type: String
}

/// Runtime inventory of one loaded class: what it responds to and carries. Own members
/// only (superclasses list for traversal); generated classes included - the runtime does
/// not distinguish them.
struct InspectClassDetail: Codable {
    var name: String
    var isMeta: Bool
    var superclasses: [String]
    var methods: [InspectMethodInfo]
    var classMethods: [InspectMethodInfo]
    var ivars: [InspectIvarInfo]
    var properties: [String]
    var protocols: [String]
    var truncated: Bool
}

/// One view in the snapshot. ids are positional index paths ("0.2.1") resolved by re-walking
/// in the SAME mode, never object addresses: stable across the walk that produced them,
/// meaningless afterwards or across modes.
struct InspectNode: Codable {
    var id: String
    var cls: String
    /// Operator-facing kind: button, text, textfield, textview, image, switch, slider,
    /// segmented, list, web, window, control, container, other. Derived from class, so custom
    /// subclasses report their nearest UIKit role (UIButton subclass -> button).
    var role: String
    var frame: [Double]   // window points: x, y, w, h
    var text: String?
    var placeholder: String?
    var axLabel: String?
    var axIdentifier: String?
    var enabled: Bool
    var secure: Bool      // true when the text was masked (redaction on + secure field)
    /// Owning UI framework, per node (nil = indistinguishable UIKit, never a guess).
    /// Inherited down subtrees, so 500 RCTView descendants cost one ancestor decision.
    var framework: String? = nil
    /// Backing layer class when it is not a plain CALayer (e.g. AVPlayerLayer,
    /// CATransformLayer) — nil otherwise, so payloads stay small and diffs only fire
    /// on real layer changes, never on old layer-less timelines.
    var layer: String? = nil
    /// Owning view controller (responder chain), so every tap answers which screen
    /// owns it without a second element read.
    var vc: String? = nil
    var children: [InspectNode]
}

/// Wire filenames both sides share (this file compiles into guest + host, so the
/// channel names are single-sourced here, not string-littered per side).
enum InspectWire {
    static let command = "inspect-cmd.json"
    static let responsePrefix = "inspect-rsp-"
    static let pumpAlive = "inspect-pump-alive"
    static let claimSuffix = ".processing"
    static func responseName(for id: String) -> String { "\(responsePrefix)\(id).json" }
    static func claimName() -> String { "\(command).\(UUID().uuidString)\(claimSuffix)" }
}
