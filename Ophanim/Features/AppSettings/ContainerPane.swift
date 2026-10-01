//
//  ContainerView.swift
//  Ophanim
//

import SwiftUI
import AppKit

/// Full app-data management for one hosted app. macOS owns each app's sandbox
/// container, so profiles are directory swaps around that OS-owned path: the live tree stays
/// where the OS expects it, named snapshots wait under Ophanim's storage, and switching parks
/// the live tree before moving the chosen profile in. Inspect, reveal, snapshot (zip via
/// ditto), clear caches vs all data, clear the saved KeyCover keychain - each destructive
/// action behind confirmation, each long operation off the main thread with a busy state so
/// double-clicks cannot overlap runs. Switching, deleting, and restoring all refuse while the
/// app runs.
struct ContainerView: View {
    let app: HostedApp

    @State private var containerExists = false
    @State private var containerSizeText = ""
    @State private var busy = false
    @State private var showClearDataConfirm = false
    @State private var showClearKeychainConfirm = false
    @State private var restoreCandidate: URL? = nil
    @State private var notice: String? = nil
    @State private var profiles: [String] = []
    @State private var activeProfile = "Default"
    @State private var newProfileName = ""
    @State private var profileToDelete: String? = nil

    private var container: AppContainer {
        AppContainer(bundleId: app.info.bundleIdentifier)
    }

    private var isAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.info.bundleIdentifier
        }
    }
    var body: some View {
        List {
            overviewSection
            profilesSection
            snapshotSection
            dangerSection
            revealSection
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .padding()
        .disabled(busy)
        .task {
            await refreshContainer()
        }
        .alert("settings.container.clearTitle", isPresented: $showClearDataConfirm) {
            Button("settings.container.clear", role: .destructive) {
                container.clear()
                Task { await refreshContainer() }
            }
            Button("button.Cancel", role: .cancel) { }
        } message: {
            Text("settings.container.clearMessage")
        }
        .alert("settings.container.clearKeychainTitle", isPresented: $showClearKeychainConfirm) {
            Button("settings.container.clearKeychain", role: .destructive) {
                for url in KeyCoverKey(appBundleID: app.info.bundleIdentifier).allFiles {
                    FileManager.default.delete(at: url)
                }
            }
            Button("button.Cancel", role: .cancel) { }
        } message: {
            Text("settings.container.clearKeychainMessage")
        }
        .alert("settings.container.restoreTitle", isPresented: Binding(
            get: { restoreCandidate != nil },
            set: { if !$0 { restoreCandidate = nil } })) {
            Button("settings.container.restore", role: .destructive) {
                if let archive = restoreCandidate {
                    restoreCandidate = nil
                    restoreContainer(from: archive)
                }
            }
            Button("button.Cancel", role: .cancel) { }
        } message: {
            Text("settings.container.restoreMessage")
        }
        .alert("settings.container.deleteProfileTitle", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } })) {
            Button("settings.container.delete", role: .destructive) {
                if let name = profileToDelete {
                    profileToDelete = nil
                    deleteProfile(name: name)
                }
            }
            Button("button.Cancel", role: .cancel) { }
        } message: {
            Text("settings.container.deleteProfileMessage")
        }
        .alert("settings.container.noticeTitle", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } })) {
            Button("button.OK", role: .cancel) { }
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
            Section("settings.container.overview") {
                HStack {
                    Text("settings.container.path")
                    Spacer()
                    Text("\(container.containerUrl.path)")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("settings.container.size")
                    Spacer()
                    Text(containerExists ? containerSizeText : NSLocalizedString("settings.container.missing", comment: ""))
                    Button("settings.container.refresh") {
                        Task { await refreshContainer() }
                    }
                    .buttonStyle(.link)
                    .disabled(busy || !containerExists)
                }
                HStack {
                    Text("settings.container.preferences")
                    Spacer()
                    Text("\(container.userPrefsUrl.path)")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("settings.container.activeProfile")
                    Spacer()
                    Text(activeProfile)
                }
            }
    }

    @ViewBuilder
    private var profilesSection: some View {
            Section("settings.container.profiles") {
                Text("settings.container.profilesDesc")
                    .foregroundStyle(.secondary)
                ForEach(profiles, id: \.self) { name in
                    HStack {
                        Image(systemName: name == activeProfile ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(name == activeProfile ? Color.accentColor : .secondary)
                        Text(name)
                        Spacer()
                        if name != activeProfile {
                            Button("settings.container.switch") {
                                switchProfile(to: name)
                            }
                            .buttonStyle(.link)
                            .disabled(busy || isAppRunning)
                            Button("settings.container.delete") {
                                profileToDelete = name
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.red)
                            .disabled(busy)
                        }
                    }
                }
                HStack {
                    TextField("settings.container.newProfile", text: $newProfileName)
                    Spacer()
                    Button("settings.container.create") {
                        createProfile()
                    }
                    .disabled(busy || newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
    }

    @ViewBuilder
    private var snapshotSection: some View {
            Section("settings.container.snapshot") {
                HStack {
                    Text("settings.container.snapshotDesc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("settings.container.backup") {
                        backupContainer()
                    }
                    .disabled(busy || !containerExists)
                    Button("settings.container.restore") {
                        pickRestoreArchive()
                    }
                    .disabled(busy)
                }
            }
    }

    @ViewBuilder
    private var dangerSection: some View {
            Section("settings.container.danger") {
                HStack {
                    Text("settings.container.cachesDesc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("settings.container.clearCaches") {
                        clearCaches()
                    }
                    .disabled(busy || !containerExists)
                }
                HStack {
                    Text("settings.container.dataDesc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("settings.container.clear", role: .destructive) {
                        showClearDataConfirm = true
                    }
                    .disabled(busy || !containerExists)
                }
                HStack {
                    Text("settings.container.keychainDesc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("settings.container.clearKeychain", role: .destructive) {
                        showClearKeychainConfirm = true
                    }
                    .disabled(busy)
                }
            }
    }

    @ViewBuilder
    private var revealSection: some View {
            Section {
                HStack {
                    Spacer()
                    Button("settings.container.reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([container.containerUrl])
                    }
                    .disabled(!containerExists)
                }
            }
    }

    private func refreshContainer() async {
        let url = container.containerUrl
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size: Int64 = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: url.path) else { return 0 }
            var total: Int64 = 0
            for sub in subpaths {
                let file = url.appendingPathComponent(sub)
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }.value
        await MainActor.run {
            containerExists = exists
            containerSizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            profiles = ContainerProfiles.profiles(bundleID: app.info.bundleIdentifier)
            activeProfile = ContainerProfiles.activeName(bundleID: app.info.bundleIdentifier)
        }
    }

    /// Profile ops run off-main (copies/moves of whole containers) with the busy guard; errors
    /// surface as notices, never as crashes, and the model refuses unsafe states itself.
    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        let bid = app.info.bundleIdentifier
        Task.detached(priority: .utility) {
            let result: Result<Void, Error> = Result {
                try ContainerProfiles.create(bundleID: bid, name: name)
            }
            await MainActor.run {
                busy = false
                switch result {
                case .success: newProfileName = ""
                case .failure(let error): notice = error.localizedDescription
                }
            }
            await refreshContainer()
        }
    }

    private func switchProfile(to name: String) {
        busy = true
        let bid = app.info.bundleIdentifier
        Task.detached(priority: .utility) {
            let result: Result<Void, Error> = Result {
                try ContainerProfiles.switchTo(bundleID: bid, name: name)
            }
            await MainActor.run {
                busy = false
                if case .failure(let error) = result {
                    notice = error.localizedDescription
                }
            }
            await refreshContainer()
        }
    }

    private func deleteProfile(name: String) {
        busy = true
        let bid = app.info.bundleIdentifier
        Task.detached(priority: .utility) {
            let result: Result<Void, Error> = Result {
                try ContainerProfiles.remove(bundleID: bid, name: name)
            }
            await MainActor.run {
                busy = false
                if case .failure(let error) = result {
                    notice = error.localizedDescription
                }
            }
            await refreshContainer()
        }
    }

    private func backupContainer() {
        guard let dest = NSSavePanel.saveZip(
            suggestedName: "\(app.info.bundleIdentifier)-container.zip") else { return }
        busy = true
        let source = container.containerUrl
        Task.detached(priority: .utility) {
            // ditto -c -k: zip that preserves symlinks, permissions, and resource forks, which a
            // FileManager copy would silently flatten. Symmetric with restoreContainer below.
            let result: Result<Void, Error> = Result {
                try Shell.run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc",
                              source.path, dest.path)
            }
            await MainActor.run {
                busy = false
                if case .failure(let error) = result {
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func pickRestoreArchive() {
        if isAppRunning {
            // Restoring under a running app replaces files it has open; refuse rather than
            // corrupt the live container.
            notice = NSLocalizedString("settings.container.restoreRunning", comment: "")
            return
        }
        guard let archive = NSOpenPanel.openZip() else { return }
        restoreCandidate = archive
    }

    private func restoreContainer(from archive: URL) {
        busy = true
        let target = container.containerUrl
        Task.detached(priority: .utility) {
            let result: Result<Void, Error> = Result {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Shell.run("/usr/bin/ditto", "-x", "-k", archive.path, target.path)
            }
            await MainActor.run {
                busy = false
                if case .failure(let error) = result {
                    notice = error.localizedDescription
                }
            }
            await refreshContainer()
        }
    }

    private func clearCaches() {
        busy = true
        let caches = container.containerUrl
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Caches")
        Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: caches.path) {
                FileManager.default.delete(at: caches)
            }
            await MainActor.run { busy = false }
            await refreshContainer()
        }
    }
}
