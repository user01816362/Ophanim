//
//  TweakLibraryVM.swift
//  Ophanim
//
//  View-model for CustomDylibView: owns the tweak list, processing state, and every
//  Galgal store call. The view renders state and forwards gestures; no engine I/O
//  lives in the view anymore (per the View/Model boundary audit).
//

import SwiftUI

@Observable class TweakLibraryVM: @unchecked Sendable {
    var items: [TweakItem] = []
    var isProcessing = false

    let app: HostedApp
    var settings: AppSettings

    init(app: HostedApp, settings: AppSettings) {
        self.app = app
        self.settings = settings
    }

    var activeStoreURL: URL {
        Galgal.effectiveTweakStore(bundleIdentifier: app.info.bundleIdentifier,
                                   customPath: settings.settings.customTweakFolder)
    }

    var isUsingCustomFolder: Bool {
        if let path = settings.settings.customTweakFolder, !path.isEmpty { return true }
        return false
    }

    var isCustomFolderAccessible: Bool {
        guard let path = settings.settings.customTweakFolder, !path.isEmpty else { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    @MainActor
    func reloadItems() async {
        let bid = app.info.bundleIdentifier
        let customPath = settings.settings.customTweakFolder
        let items = await Task.detached(priority: .userInitiated) {
            Galgal.tweakItems(bundleIdentifier: bid, customPath: customPath)
        }.value
        self.items = items
    }

    /// Single shape for every mutating op: processing flag, background work, error
    /// toast, list refresh. Callers pass only the Galgal call.
    private final class WorkBox: @unchecked Sendable {
        let fn: () throws -> Void
        init(_ fn: @escaping () throws -> Void) { self.fn = fn }
    }

    func performTweakOp(_ work: @escaping () throws -> Void) {
        isProcessing = true
        let box = WorkBox(work)
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try box.fn()
            } catch {
                Log.shared.error(error)
                Task { @MainActor in
                    ToastVM.shared.showToast(toastType: .error, toastDetails: error.localizedDescription)
                }
            }
            await self.reloadItems()
            await MainActor.run { self.isProcessing = false }
        }
    }

    func chooseCustomFolder() {
        NSOpenPanel.selectTweakFolder { [weak self] result in
            guard case .success(let folderURL) = result, let self else { return }
            settings.settings.customTweakFolder = folderURL.path
            performTweakOp {
                try Galgal.syncUserDylibs(bundleIdentifier: self.app.info.bundleIdentifier,
                                          into: self.app.executable,
                                          customPath: folderURL.path)
            }
        }
    }

    func resetCustomFolder() {
        settings.settings.customTweakFolder = nil
        performTweakOp { [weak self] in
            guard let self else { return }
            try Galgal.syncUserDylibs(bundleIdentifier: app.info.bundleIdentifier,
                                      into: app.executable,
                                      customPath: nil)
        }
    }

    func toggleEnabled(item: TweakItem, enabled: Bool) {
        performTweakOp { [weak self] in
            guard let self else { return }
            try Galgal.setTweakEnabled(item: item,
                                       enabled: enabled,
                                       bundleIdentifier: app.info.bundleIdentifier,
                                       appExecutable: app.executable,
                                       customPath: settings.settings.customTweakFolder)
        }
    }

    func selectAndAddTweak() {
        NSOpenPanel.selectTweakItem { [weak self] result in
            guard case .success(let url) = result, let self else { return }
            performTweakOp {
                try Galgal.addTweakItem(at: url,
                                        bundleIdentifier: self.app.info.bundleIdentifier,
                                        appExecutable: self.app.executable,
                                        customPath: self.settings.settings.customTweakFolder)
            }
        }
    }

    func removeItem(_ item: TweakItem) {
        performTweakOp { [weak self] in
            guard let self else { return }
            try Galgal.removeTweakItem(item: item,
                                       bundleIdentifier: app.info.bundleIdentifier,
                                       appExecutable: app.executable,
                                       customPath: settings.settings.customTweakFolder)
        }
    }

    func createSubfolder(named name: String) {
        performTweakOp { [weak self] in
            guard let self else { return }
            try Galgal.createNewSubfolder(named: name,
                                          bundleIdentifier: app.info.bundleIdentifier,
                                          customPath: settings.settings.customTweakFolder)
        }
    }
}
