//
//  Logger.swift
//  Ophanim
//

import Foundation
import SwiftUI

@Observable class Log: @unchecked Sendable {

    nonisolated(unsafe) static let shared = Log()

    func error(_ err: Error) {
        let message = err.localizedDescription
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: message,
                style: NSAlert.Style.critical)
        }
    }

    func error(localized str: String, args: [String] = []) {
        error(String(format: NSLocalizedString(str, comment: ""), arguments: args))
    }

    func msg(_ msg: String) {
        Task { @MainActor in
            self.log(msg)
            self.dialog(
                question: NSLocalizedString("alert.success", comment: ""),
                text: msg,
                style: NSAlert.Style.informational)
        }
    }

    var logdata = "\(ProcessInfo.processInfo.operatingSystemVersionString)\n"

    func log(_ str: String, isError: Bool = false) {
        print(str)
        if isError {
            logdata.append("ERROR: ")
        }
        logdata.append(str)
        logdata.append("\n")
    }

    @MainActor
    private func dialog(question: String, text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
        alert.runModal()
    }

    /// Centralized modal dialogs (R11: `runModal` lives here only; sheets, which
    /// need a local window, stay at their call sites). Must run on the main thread,
    /// like every `runModal` call it replaces.
    @MainActor
    static func modal(question: String, text: String,
                      style: NSAlert.Style = .informational,
                      buttons: [String],
                      makeFirstDefault: Bool = false,
                      suppressionTooltip: String? = nil,
                      accessory: NSView? = nil)
    -> (response: NSApplication.ModalResponse, suppressed: Bool) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = style
        for (i, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            if i == 0 && makeFirstDefault { button.keyEquivalent = "\r" }
        }
        if let tip = suppressionTooltip {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = tip
        }
        if let accessory { alert.accessoryView = accessory }
        let response = alert.runModal()
        return (response, alert.suppressionButton?.state == .on)
    }

    /// Two-button question. Returns true when the first button is chosen.
    @MainActor
    static func confirm(question: String, text: String,
                        style: NSAlert.Style = .warning,
                        ok: String, cancel: String) -> Bool {
        let (response, _) = modal(question: question, text: text, style: style,
                                  buttons: [ok, cancel])
        return response == .alertFirstButtonReturn
    }

    /// One-button notice.
    @MainActor
    static func notify(question: String, text: String, style: NSAlert.Style = .warning) {
        let ok = NSLocalizedString("button.OK", comment: "")
        _ = modal(question: question, text: text, style: style, buttons: [ok])
    }

    required init() { }
}
