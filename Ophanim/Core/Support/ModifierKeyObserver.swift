//
//  ModifierKeyObserver.swift
//  Ophanim
//
//  Created by Venti on 14/02/2024.
//

import Foundation

@Observable class ModifierKeyObserver {
    nonisolated(unsafe) static let shared = ModifierKeyObserver()

    var isOptionKeyPressed = false
    var isCommandKeyPressed = false
    var isControlKeyPressed = false
    var isShiftKeyPressed = false

    private var eventMonitor: Any?

    init() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .flagsChanged {
//                debugPrint("Event received: \(event)")
                self.isOptionKeyPressed = event.modifierFlags.contains(.option)
                self.isCommandKeyPressed = event.modifierFlags.contains(.command)
                self.isControlKeyPressed = event.modifierFlags.contains(.control)
                self.isShiftKeyPressed = event.modifierFlags.contains(.shift)
            }
            return event
        }
    }

    deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
