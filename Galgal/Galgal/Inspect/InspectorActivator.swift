//
//  InspectorActivator.swift
//  Galgal
//
//  Tap synthesis through the product's own touch path - Toucher.touchcam, the same
//  PTFakeMetaTouch mechanism Galgal's Mac-mouse controls use for every hosted app. No new
//  touch primitive, no CGEventPost (out-of-process, needs trust), no PTFakeTouch fork.
//
//  Two contracts, both load-bearing:
//  - key window only. Toucher re-derives the key window internally (and force-unwraps it),
//    so tapping any other window would deliver to the wrong target or crash. The caller
//    guarantees window.isKeyWindow; this function re-checks because a crash is forever.
//  - phases split across runloop turns. began and ended in the same tick collapse: the fake
//    touch signals the runloop source and delivery happens later, by which time the phase is
//    already Ended and the Began never runs. So began runs now (guarded: nil tid afterwards
//    means refused upstream) and ended queues on the next main turn. acted:true therefore
//    means "began accepted, ended queued", not "delivered" - stated, not implied.
//

import UIKit

enum InspectorActivator {
    /// Tap by window point in a key window. Returns whether the touch was dispatched and to what.
    ///
    /// Began runs now and ended queues on the next main turn (same-tick began+ended collapse,
    /// so they must split across runloop turns). acted:true means "began accepted, ended
    /// queued", not "delivered".
    ///
    /// - Parameter point: Window point to tap (must lie in bounds).
    /// - Parameter window: Key window receiving the touch.
    /// - Returns: Whether the touch dispatched, plus the hit-tested target class.
    static func tap(at point: CGPoint, in window: UIWindow) -> (acted: Bool, targetClass: String?) {
        guard window.isKeyWindow, window.bounds.contains(point) else { return (false, nil) }
        let target = window.hitTest(point, with: nil)
        let cls = target.map { String(describing: type(of: $0)) }

        var tid: Int? = nil
        Toucher.touchcam(point: point, phase: .began, tid: &tid,
                         actionName: "inspect", keyName: "tap")
        guard tid != nil else { return (false, cls) }
        let captured = tid
        DispatchQueue.main.async {
            var endTid: Int? = captured
            Toucher.touchcam(point: point, phase: .ended, tid: &endTid,
                             actionName: "inspect", keyName: "tap")
        }
        return (true, cls)
    }

    /// Swipe: began, interpolated moved phases, ended. moved phases go through the same
    /// touchcam path (any phase flows to the fake touch); a short runloop spin between
    /// phases lets each deliver instead of collapsing into a lone Ended (same reason tap's
    /// ended waits a turn). acted means began accepted, like tap.
    static func swipe(from: CGPoint, to: CGPoint, steps: Int, in window: UIWindow) -> (acted: Bool, targetClass: String?) {
        guard window.isKeyWindow, window.bounds.contains(from), window.bounds.contains(to) else {
            return (false, nil)
        }
        let target = window.hitTest(from, with: nil)
        let cls = target.map { String(describing: type(of: $0)) }

        var tid: Int? = nil
        Toucher.touchcam(point: from, phase: .began, tid: &tid,
                         actionName: "inspect", keyName: "swipe")
        guard tid != nil else { return (false, cls) }
        let n = min(max(steps, 1), 20)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t,
                            y: from.y + (to.y - from.y) * t)
            var moveTid = tid
            Toucher.touchcam(point: p, phase: .moved, tid: &moveTid,
                             actionName: "inspect", keyName: "swipe")
            tid = moveTid
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let captured = tid
        let end = to
        DispatchQueue.main.async {
            var endTid: Int? = captured
            Toucher.touchcam(point: end, phase: .ended, tid: &endTid,
                             actionName: "inspect", keyName: "swipe")
        }
        return (true, cls)
    }

    /// SetText: direct property write + change notification, no fake typing. Focus side
    /// effects (delegates, keyboards) do NOT run - tap the field first when the app needs
    /// them. Works on secure fields; the text comes from the operator, so redaction (which
    /// guards what flows OUT) does not apply. Only UITextField/UITextView accept text;
    /// anything else fails stated (the pump then tries typeText below).
    ///
    /// - Parameter text: Replacement text for the field.
    /// - Parameter view: Target view (must be a text field or text view).
    /// - Returns: True when the write landed.
    static func setText(_ text: String, in view: UIView) -> Bool {
        if let field = view as? UITextField {
            field.text = text
            field.sendActions(for: .editingChanged)
            return true
        }
        if let tv = view as? UITextView {
            tv.text = text
            NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: tv)
            return true
        }
        return false
    }

    /// TypeText fallback for inputs setText cannot address (engine-rendered fields like
    /// Flutter's hidden UITextInput bridge, custom controls): tap to focus, then
    /// `insertText` into whatever became first responder (Apple's public UIKeyInput
    /// primitive — the same call a custom keyboard makes). Fully in-process: responder
    /// chain + UIKeyInput, no HID/TCC involved. Refuses web content (WKWebView inputs
    /// need JS key events; a blind insert would desync page state) and reports the
    /// focused control's class so the response names what actually took the text.
    ///
    /// - Parameter text: Text to insert at the focused input's cursor.
    /// - Parameter point: Window point to tap for focus (element center).
    /// - Parameter window: Key window hosting the point.
    /// - Returns: Whether text was inserted, and the focused control's class.
    static func typeText(_ text: String, at point: CGPoint, in window: UIWindow)
    -> (acted: Bool, targetClass: String?) {
        let (focused, _) = tap(at: point, in: window)
        guard focused else { return (false, nil) }
        // Let focus land (same runloop-turn constraint as swipe phases).
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let first = currentFirstResponder() else { return (false, nil) }
        let cls = String(describing: type(of: first))
        // Web inputs drive page state through JS; inserting behind its back corrupts it.
        var ancestor: UIResponder? = first
        while let a = ancestor {
            if String(describing: type(of: a)).contains("WKWebView") { return (false, cls) }
            ancestor = a.next
        }
        guard let input = first as? UITextInput else { return (false, cls) }
        input.insertText(text)
        return (true, cls)
    }

    /// Current first responder via the standard sendAction probe (no private API:
    /// the action travels the responder chain and the focused object answers it).
    ///
    /// - Returns: The focused responder, or nil when nothing is focused.
    private static func currentFirstResponder() -> UIResponder? {
        opFoundFirstResponder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.opNoteFirstResponder(_:)),
                                        to: nil, from: nil, for: nil)
        return opFoundFirstResponder
    }
}

/// File-private first-responder slot for the probe above (weak: never retains app objects).
private weak var opFoundFirstResponder: UIResponder?

extension UIResponder {
    /// Probe target: the focused responder records itself when the action reaches it.
    ///
    /// - Parameter sender: Always nil for this probe.
    @objc func opNoteFirstResponder(_ sender: Any?) {
        opFoundFirstResponder = self
    }
}
