//
//  HostedAppVM.swift
//  Ophanim
//
//  Created by Adam Chen JingFan on 4/7/24.
//

import SwiftUI

@Observable class HostedAppVM: @unchecked Sendable {
    var app: HostedApp
    var showClearPreferencesAlert = false
    var showClearChainGuardAlert = false
    var showStartingProgress = false
    var showImportSuccess = false
    var showImportFail = false
    var showKeymapSheet = false

    init(app: HostedApp) {
        self.app = app
    }
}
