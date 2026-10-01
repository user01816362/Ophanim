//
//  Inspector.swift
//  Galgal
//
//  In-process UI-tree snapshot. Walks UIWindowScene windows and their subview trees directly:
//  no Accessibility APIs (no trust prompt, no out-of-process broker), no private selectors
//  (FLEX's allWindowsIncludingInternalWindows: is exactly what we do NOT copy).
//
//  Latest-API notes, verified against the on-disk SDK, not recalled:
//  - windows come from UIApplication.connectedScenes -> UIWindowScene.windows. The static
//    UIApplication.shared.keyWindow / UIScreen.main accessors are deprecated; the instance
//    window.isKeyWindow property used for ordering is current.
//  - text comes from UILabel/UITextField/UITextView/UIButton - all current. Secure-entry
//    masking keys off UITextField.isSecureTextEntry, current.
//  - runtime introspection below (objc_copyClassList, class_getSuperclass) is public ObjC
//    runtime API, swept clean in the SDK headers. View-controller lookup walks the public
//    responder chain, not the private _viewControllerForAncestor.
//  - WKWebView content is not traversable in-process; reported as an opaque node, never faked.
//

import UIKit

enum Inspector {
    static let maxDepth = 24
    static let maxNodes = 2000
    static let maxClassNames = 2000

    /// The one window taps and screenshots target. Every path that picks a window funnels
    /// through here, so tree frames, pixels, and touches can never disagree about which window
    /// they mean (multi-window apps: alerts, keyboard, PiP).
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }.filter { !$0.isHidden && $0.alpha > 0.01 }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    static func sortedWindows() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var windows = scenes.flatMap { $0.windows }
        windows.sort { ($0.isKeyWindow ? 0 : 1, $0.windowLevel.rawValue) <
                      ($1.isKeyWindow ? 0 : 1, $1.windowLevel.rawValue) }
        return windows
    }

    /// Operator-facing role, nearest UIKit ancestor first so custom subclasses report sanely
    /// (UIButton subclass -> button). Order matters: specific controls before UIControl.
    static func role(of view: UIView) -> String {
        let name = String(describing: type(of: view))
        if name.contains("WKWebView") { return "web" }
        switch view {
        case is UIButton: return "button"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UISegmentedControl: return "segmented"
        case is UITextField: return "textfield"
        case is UITextView: return "textview"
        case is UILabel: return "text"
        case is UIImageView: return "image"
        case is UITableView: return "list"
        case is UICollectionView: return "list"
        case is UIWindow: return "window"
        case is UIControl: return "control"
        default: return view.subviews.isEmpty ? "other" : "container"
        }
    }

    /// Shared text extraction: walk, resolve, and redaction all classify identically, so an id
    /// resolved later sees the same text the tree showed. Single source of truth, not three.
    static func classify(_ view: UIView) -> (text: String?, placeholder: String?, secure: Bool) {
        if let label = view as? UILabel {
            return (label.text, nil, false)
        } else if let field = view as? UITextField {
            return (field.text, field.placeholder, field.isSecureTextEntry)
        } else if let tv = view as? UITextView {
            return (tv.text, nil, false)
        } else if let button = view as? UIButton {
            return (button.currentTitle, nil, false)
        }
        return (nil, nil, false)
    }

    static func visibleChildren(of view: UIView) -> [UIView] {
        view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }
    }

    /// Compact-mode collapse: a plain UIView (exact class, not a subclass carrying behavior)
    /// with no text, placeholder, identifier, or control of its own is layout scaffolding -
    /// the 20-deep chains UIKit builds. Single-child chains collapse into the child.
    static func isCollapsible(_ view: UIView) -> Bool {
        guard type(of: view) == UIView.self, !(view is UIControl) else { return false }
        let (text, placeholder, _) = classify(view)
        return (text?.isEmpty ?? true) && (placeholder?.isEmpty ?? true) &&
               (view.accessibilityIdentifier?.isEmpty ?? true)
    }

    /// Follow a collapse chain to the first meaningful view (same id slot as the top).
    static func collapse(_ view: UIView) -> UIView {
        var target = view
        while isCollapsible(target) {
            let kids = visibleChildren(of: target)
            guard kids.count == 1 else { break }
            target = kids[0]
        }
        return target
    }

    /// Snapshot every window, key window first. Pure read: no first-responder changes, no layout.
    /// Agent-narrowable caps (depthLimit/nodeLimit) only ever narrow the hard ceilings -
    /// the guest clamps, never raises.
    static func snapshot(redact: Bool, mode: InspectMode, filter: String?,
                         maxDepth: Int = maxDepth, maxNodes: Int = maxNodes)
    -> (nodes: [InspectNode], truncated: Bool, truncatedBy: [String]) {
        let depthCap = min(max(maxDepth, 1), maxDepth)
        let nodeCap = min(max(maxNodes, 1), maxNodes)
        let windows = sortedWindows()
        var nodes: [InspectNode] = []
        var truncated = false
        var depthCut = false
        var nodeCut = false
        var budget = nodeCap
        for (wi, window) in windows.enumerated() {
            guard !window.isHidden, window.alpha > 0.01 else { continue }
            if budget <= 0 { truncated = true; nodeCut = true; break }
            let (node, used, dCut, nCut) = walk(window, id: "\(wi)", window: window,
                                               depth: 0, budget: budget, redact: redact,
                                               mode: mode, filter: filter, maxDepth: depthCap)
            budget -= used
            truncated = truncated || dCut || nCut
            depthCut = depthCut || dCut
            nodeCut = nodeCut || nCut
            if let node = node { nodes.append(node) }
        }
        var by: [String] = []
        if depthCut { by.append("depth") }
        if nodeCut { by.append("nodes") }
        return (nodes, truncated, by)
    }

    /// Resolve a positional id ("0.2.1") by re-walking IN THE SAME MODE. ids are only meaningful
    /// against a snapshot taken in that mode; mixing modes fails stated. A view that moved or
    /// vanished resolves to nil, reported, never guessed.
    static func resolve(elementId: String, mode: InspectMode) -> (view: UIView, window: UIWindow, cls: String)? {
        let parts = elementId.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let windows = sortedWindows()
        guard parts[0] < windows.count else { return nil }
        let window = windows[parts[0]]
        // Window roots are never collapsed (they are not plain UIViews), so index 0 is direct.
        var current: UIView = window
        for index in parts.dropFirst() {
            // Mirror walk exactly: collapse the current node first, then index its children.
            let target = (mode == .compact) ? collapse(current) : current
            let kids: [UIView]
            if mode == .compact, isCollapsible(target), visibleChildren(of: target).isEmpty {
                return nil // walk dropped this leaf; the id cannot resolve in this mode
            }
            kids = visibleChildren(of: target)
            guard index < kids.count else { return nil }
            current = kids[index]
        }
        let final = (mode == .compact) ? collapse(current) : current
        return (final, window, String(describing: type(of: final)))
    }

    /// Superclass chain, nearest first, capped. Public runtime API.
    static func superclasses(of view: UIView) -> [String] {
        var out: [String] = []
        var cls: AnyClass? = class_getSuperclass(type(of: view))
        while let c = cls, out.count < 8 {
            out.append(NSStringFromClass(c))
            cls = class_getSuperclass(c)
        }
        return out
    }

    /// Owning view controller via the public responder chain. Nil for window-level views.
    static func viewController(of view: UIView) -> String? {
        var next: UIResponder? = view.next
        while let r = next {
            if let vc = r as? UIViewController { return String(describing: type(of: vc)) }
            next = r.next
        }
        return nil
    }

    /// Every loaded ObjC class, with total. The enumeration itself runs in C
    /// (InspectCopyLoadedClassNames): Swift must never malloc/free the class-list buffer.
    /// Thousands of system classes are normal - filter first. Autorelease-pooled: tens of
    /// thousands of temporary names would otherwise sit until the runloop drains.
    static func runtimeClasses(filter: String?, limit: Int) -> (names: [String], total: Int) {
        let all: [String] = autoreleasepool {
            (InspectCopyLoadedClassNames() as [String]?) ?? []
        }
        let total = all.count
        var names = all
        if let f = filter, !f.isEmpty {
            names = names.filter { $0.localizedCaseInsensitiveContains(f) }
        }
        names.sort()
        return (Array(names.prefix(min(max(limit, 0), maxClassNames))), total)
    }

    /// Runtime inventory of one class for hook targeting. The ObjC side returns only
    /// Foundation values (all copy/free pairs stay in C); the JSON round-trip lands them
    /// in the shared Codable shape. Everything happens inside the pool: the returned
    /// dictionary is autoreleased, and only Swift-owned decoded values leave it.
    static func classDetail(name: String) -> InspectClassDetail? {
        autoreleasepool {
            guard let dict = InspectCopyClassDetail(name),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let detail = try? JSONDecoder().decode(InspectClassDetail.self, from: data) else {
                return nil
            }
            return detail
        }
    }

    // MARK: - Walk (internal: the screenshot path reuses it for per-window redaction)

    /// Secure-field frames within ONE window, in that window's coordinates. Always full mode:
    /// redaction must cover everything even when the operator asked for a compact tree.
    /// Scoped (not the whole forest) because the screenshot only ever captures one window -
    /// forest-wide frames would paint black boxes at coordinates that mean something else in
    /// the captured window.
    static func secureFrames(in window: UIWindow) -> [CGRect] {
        let (node, _, _, _) = walk(window, id: "0", window: window,
                                 depth: 0, budget: maxNodes, redact: true,
                                 mode: .full, filter: nil)
        guard let node = node else { return [] }
        var out: [CGRect] = []
        collectSecureFrames(node, into: &out)
        return out
    }

    static func matches(_ view: UIView, cls: String, text: String?, filter: String?) -> Bool {
        guard let f = filter, !f.isEmpty else { return true }
        if cls.localizedCaseInsensitiveContains(f) { return true }
        if let text, text.localizedCaseInsensitiveContains(f) { return true }
        if let label = view.accessibilityLabel,
           label.localizedCaseInsensitiveContains(f) { return true }
        return false
    }

    /// Returns the node (nil when over budget, dropped, or filtered), units consumed,
    /// and the two cut flags separately: depth-driven vs node-budget-driven. Callers OR
    /// them up; a subtree can carry both, and inference from one bool would lose that.
    static func walk(_ view: UIView, id: String, window: UIWindow,
                     depth: Int, budget: Int, redact: Bool,
                     mode: InspectMode, filter: String?, maxDepth: Int = maxDepth)
    -> (InspectNode?, Int, Bool, Bool) {
        guard budget > 0 else { return (nil, 0, false, true) }
        guard depth <= maxDepth else { return (nil, 0, true, false) }
        // Compact: descend collapse chains (same id slot) or drop empty scaffolding leaves.
        let target: UIView
        if mode == .compact {
            target = collapse(view)
            if target !== view && visibleChildren(of: target).isEmpty && isCollapsible(target) {
                return (nil, 1, false, false)
            }
            if target === view, isCollapsible(view), visibleChildren(of: view).isEmpty {
                return (nil, 1, false, false)
            }
        } else {
            target = view
        }
        var consumed = 1
        let frame = target.convert(target.bounds, to: window)
        let cls = String(describing: type(of: target))
        var (text, placeholder, secure) = classify(target)
        if redact, secure {
            text = text.map { $0.isEmpty ? $0 : "•••" }
        }

        var children: [InspectNode] = []
        var depthCut = false
        var nodeCut = false
        // Web content is opaque in-process: report the container, never invent children.
        let isWeb = cls.contains("WKWebView")
        if !isWeb {
            let kids = visibleChildren(of: target)
            for (i, kid) in kids.enumerated() {
                guard consumed < budget else { nodeCut = true; break }
                let (child, used, dCut, nCut) = walk(kid, id: "\(id).\(i)", window: window,
                                                     depth: depth + 1, budget: budget - consumed,
                                                     redact: redact, mode: mode, filter: filter,
                                                     maxDepth: maxDepth)
                consumed += used
                depthCut = depthCut || dCut
                nodeCut = nodeCut || nCut
                if let child = child { children.append(child) }
            }
        }

        // Filtered out (and no kept descendant): prune, but still consume the unit.
        let selfMatch = matches(target, cls: cls, text: text, filter: filter)
        if !selfMatch, children.isEmpty {
            return (nil, consumed, depthCut, nodeCut)
        }

        let node = InspectNode(
            id: id, cls: cls, role: role(of: target),
            frame: [Double(frame.origin.x), Double(frame.origin.y),
                    Double(frame.size.width), Double(frame.size.height)],
            text: (text?.isEmpty == false) ? text : nil,
            placeholder: (placeholder?.isEmpty == false) ? placeholder : nil,
            axLabel: target.accessibilityLabel, axIdentifier: target.accessibilityIdentifier,
            enabled: (target as? UIControl)?.isEnabled ?? true,
            secure: secure && redact,
            children: children)
        return (node, consumed, depthCut, nodeCut)
    }

    private static func collectSecureFrames(_ node: InspectNode, into out: inout [CGRect]) {
        if node.secure {
            out.append(CGRect(x: node.frame[0], y: node.frame[1],
                              width: node.frame[2], height: node.frame[3]))
        }
        for child in node.children { collectSecureFrames(child, into: &out) }
    }
}
