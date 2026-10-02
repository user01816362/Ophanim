//
//  AppSettingsVM.swift
//  Ophanim
//
//  App-settings editor view model.
//  Created by 이승윤 on 2022/08/15.
//

import Foundation

@Observable class AppSettingsVM: @unchecked Sendable {
    let app: HostedApp
    var settings: AppSettings

    init(app: HostedApp) {
        self.app = app
        settings = app.settings
    }
}
