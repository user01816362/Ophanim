//
//  KeymapViewVM.swift
//  Ophanim
//
//  Keymap editor view model.
//  Created by TheMoonThatRises on 6/20/25.
//

import SwiftUI
import DataCache

@Observable class KeymapViewVM: @unchecked Sendable {

    public let app: HostedApp
    public let cache = DataCache.instance

    var selectedKeymap: URL?
    var kmName = ""

    var defaultKm: URL

    var showKeymapImport = false
    var showKeymapRename = false
    var showCreateKeymap = false

    var appIcon: NSImage?

    var keymapURLS: [URL] = [] {
        didSet {
            app.keymapping.keymapConfig.keymapOrder = keymapURLS
        }
    }

    init(app: HostedApp) {
        self.app = app

        self.defaultKm = app.keymapping.keymapConfig.defaultKm

        self.reloadKeymapCache()
    }

    func reloadKeymapCache() {
        app.keymapping.reloadKeymapCache()

        keymapURLS = app.keymapping.keymapConfig.keymapOrder
    }

    func setDefaultKeymap(keymap: URL) {
        app.keymapping.keymapConfig.defaultKm = keymap
        defaultKm = keymap
    }

}
