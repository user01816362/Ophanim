//
//  HostedApp+Power.swift
//  Ophanim
//

import Foundation
import IOKit.pwr_mgt
// MARK: - Management
extension HostedApp {
    func disableTimeOut() {
        if displaySleepAssertionID != nil { return }

        let reason = "Ophanim: \(info.bundleIdentifier) is disabling sleep" as CFString
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            displaySleepAssertionID = assertionID
        }
    }

    func enableTimeOut() {
        if let assertionID = displaySleepAssertionID {
            IOPMAssertionRelease(assertionID)
            displaySleepAssertionID = nil
        }
    }
}
