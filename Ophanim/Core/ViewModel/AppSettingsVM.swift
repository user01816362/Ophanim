//
//  AppSettingsVM.swift
//  Ophanim
//
//  Created by 이승윤 on 2022/08/15.
//

import Foundation

@Observable class AppSettingsVM {
    let app: HostedApp
    var settings: AppSettings

    init(app: HostedApp) {
        self.app = app
        settings = app.settings
    }
}
