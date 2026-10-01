//
//  AppSourcesView.swift
//  Ophanim
//
//  App Sources window: browse downloadable apps from user-added source feeds (AltStore
//  format) and import them through the same Installer pipeline as the import-IPA button.
//  Opens as a standalone, resizable, non-modal NSWindow (one instance - re-opening
//  brings it forward) and re-fetches every source on each open, so the list is live.
//  Adding a feed is the in-window plus button, mirroring the library's import button.
//

import SwiftUI
import AppKit

/// Single-instance sources window. Mirrors LogWindowManager: the SwiftUI content must not
/// drive the window size (its stretched list makes the preferred size ambiguous), so
/// setContentSize is the source of truth and the content fills it.
final class SourcesWindowManager: NSObject, @unchecked Sendable {
    static let shared = SourcesWindowManager()

    @MainActor
    func show() {
        SettingsWindowManager.shared.show(key: "sources",
                                          title: NSLocalizedString("sources.window.title", comment: ""),
                                          size: NSSize(width: 980, height: 680),
                                          minSize: NSSize(width: 640, height: 440),
                                          contentDrivenSize: true,
                                          content: AppSourcesView())
        // Every open re-fetches: feeds change upstream, and the cached last-good state
        // renders meanwhile, so the window is never empty while it refreshes.
        Task { @MainActor in await AppSourcesStore.shared.refreshAll() }
    }
}

struct AppSourcesView: View {
    @Bindable private var store = AppSourcesStore.shared
    @Bindable private var installs = SourceInstalls.shared

    @State private var searchString = ""
    @State private var expandedSources: Set<URL> = []
    @State private var showAddSheet = false
    @State private var sourcePendingRemoval: SourceItem?

    var body: some View {
        Group {
            if store.sources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("sources.empty.title")
                        .font(.title2).bold()
                    Text("sources.empty.subtitle")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("sources.add") { showAddSheet = true }
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.sources) { item in
                        DisclosureGroup(isExpanded: binding(for: item.url)) {
                            sourceContent(for: item)
                        } label: {
                            HStack(spacing: 10) {
                                SourceFeedIcon(url: item.source?.iconURL)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName).font(.headline)
                                    if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if item.source == nil, let host = item.url.host {
                                        Text(host)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                let updates = updateCount(for: item)
                                if updates > 0 {
                                    Text("sources.updates \(updates)")
                                        .font(.caption2).bold()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.blue))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.isRefreshingAll {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("sources.refreshAll")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Plus mirrors the library's import button: it adds a source URL.
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .help("sources.add")
            }
        }
        .searchable(text: $searchString, placement: .toolbar)
        .navigationTitle("sources.window.title")
        .sheet(isPresented: $showAddSheet) {
            ManageSourcesSheet(store: store)
        }
        .alert("sources.remove.title", isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("button.Remove", role: .destructive) {
                if let item = sourcePendingRemoval { store.removeSource(item) }
                sourcePendingRemoval = nil
            }
            Button("button.Cancel", role: .cancel) { sourcePendingRemoval = nil }
        } message: {
            Text(sourcePendingRemoval?.displayName ?? "")
        }
    }

    // MARK: - Sections

    /// Apps in this feed with a newer compatible build than installed (badge count).
    private func updateCount(for item: SourceItem) -> Int {
        item.source?.apps.filter { installs.rowState(for: $0) == .update }.count ?? 0
    }

    private func binding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { isFiltering || expandedSources.contains(url) },
            set: { expanded in
                if expanded { expandedSources.insert(url) } else { expandedSources.remove(url) }
            })
    }

    private var isFiltering: Bool {
        !searchString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func sourceContent(for item: SourceItem) -> some View {
        if let error = item.error, item.source == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("sources.retry") {
                    Task { await store.refreshSource(item) }
                }
                .font(.callout)
            }
            .padding(.vertical, 4)
        } else if let source = item.source {
            let apps = filteredApps(in: source)
            if apps.isEmpty {
                Text("sources.noApps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(apps.prefix(100)) { app in
                    SourceAppRow(app: app, feedName: source.name,
                                 news: source.news.filter { $0.appID == app.bundleIdentifier })
                }
                if apps.count > 100 {
                    Text("sources.tooManyApps \(apps.count - 100)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func filteredApps(in source: AppSource) -> [SourceApp] {
        let query = searchString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return source.apps }
        return source.apps.filter {
            $0.name.lowercased().contains(query)
                || $0.bundleIdentifier.lowercased().contains(query)
                || ($0.developerName?.lowercased().contains(query) ?? false)
        }
    }

    // MARK: - Install (owned by SourceInstalls; the view only starts/pauses it)

    /// Row affordance state machine (App-Store vocabulary): Install / Reinstall /
    /// Update by installed-vs-feed comparison; ring + pause/resume/cancel while
    /// transferring; spinner while the installer runs. All state lives in the store,
    /// so closing this window never interrupts a transfer.
}

// MARK: - Rows and sheets

private struct SourceAppRow: View {
    let app: SourceApp
    let feedName: String
    let news: [SourceNews]
    @Bindable private var installs = SourceInstalls.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                SourceFeedIcon(url: app.iconURL)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.headline).lineLimit(1)
                        if app.isBeta {
                            Text("sources.badge.beta")
                                .font(.caption2).bold()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                        }
                        if installs.rowState(for: app) == .update {
                            Text("sources.badge.update")
                                .font(.caption2).bold()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.blue))
                        }
                    }
                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let subtitle = subtitleText, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if installs.latestCompatible(app) == nil {
                        Text("sources.error.noVersions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                affordance
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !app.versions.isEmpty { expanded.toggle() }
            }
            if expanded {
                versionsList
                if let description = app.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(news) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.caption).bold()
                        if let caption = item.caption, !caption.isEmpty {
                            Text(caption).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if case .failed(let message) = installs.state(for: app.bundleIdentifier) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    /// The App-Store state machine: Install / Reinstall / Update by
    /// installed-vs-feed comparison; ring while transferring (tap = pause/resume,
    /// extra actions in the context menu); spinner while installing.
    @ViewBuilder
    private var affordance: some View {
        let bid = app.bundleIdentifier
        switch installs.state(for: bid) {
        case .idle:
            switch installs.rowState(for: app) {
            case .install:
                Button("button.Install") {
                    if let v = installs.latestCompatible(app) { installs.start(app: app, version: v) }
                }
                .disabled(installs.latestCompatible(app) == nil)
                .help(app.latestVersion == nil ? "sources.error.missingDownload" : "button.Install")
            case .reinstall:
                Button("sources.reinstall") {
                    if let v = installs.latestCompatible(app) { installs.start(app: app, version: v) }
                }
                .disabled(installs.latestCompatible(app) == nil)
                .help("sources.reinstall")
            case .update:
                Button("sources.update") {
                    if let v = installs.latestCompatible(app) { installs.start(app: app, version: v) }
                }
                .disabled(installs.latestCompatible(app) == nil)
                .help("sources.update")
                .buttonStyle(.borderedProminent)
            }
        case .downloading(let progress):
            transferRing(progress: progress, paused: false)
        case .paused(let progress):
            transferRing(progress: progress, paused: true)
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            Button("sources.retry") {
                let v = installs.versionObject(for: bid) ?? installs.latestCompatible(app)
                if let v { installs.start(app: app, version: v) }
            }
            .help("sources.retry")
        }
    }

    /// Determinate ring while bytes are counted, indeterminate while the length is
    /// unknown. Tap pauses/resumes (App-Store click behavior); the context menu
    /// carries pause/resume + cancel explicitly.
    private func transferRing(progress: Double?, paused: Bool) -> some View {
        let bid = app.bundleIdentifier
        return Group {
            if paused {
                Image(systemName: "pause.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .onTapGesture {
            if paused {
                let v = installs.versionObject(for: bid) ?? installs.latestCompatible(app)
                if let v { installs.resume(bundleID: bid, version: v) }
            } else {
                installs.pause(bundleID: bid)
            }
        }
        .contextMenu {
            if paused {
                Button("sources.resume") {
                    let v = installs.versionObject(for: bid) ?? installs.latestCompatible(app)
                    if let v { installs.resume(bundleID: bid, version: v) }
                }
            } else {
                Button("sources.pause") { installs.pause(bundleID: bid) }
            }
            Button("sources.cancel", role: .destructive) { installs.cancel(bundleID: bid) }
        }
    }

    /// Every feed version with source attribution: version (build) + date + size +
    /// changelog, installed marker, per-version install.
    private var versionsList: some View {
        let installed = installs.installedVersion(for: app.bundleIdentifier)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(app.versions.indices, id: \.self) { i in
                let v = app.versions[i]
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(v.version).font(.caption).bold()
                            if let build = v.buildVersion, !build.isEmpty {
                                Text("(\(build))").font(.caption2).foregroundStyle(.secondary)
                            }
                            if installed?.version == v.version {
                                Text("sources.installed").font(.caption2).foregroundStyle(.green)
                            }
                            Text(feedName).font(.caption2).foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 4) {
                            if let date = v.date, !date.isEmpty {
                                Text(date).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let size = v.size, size > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let min = v.minOSVersion, !min.isEmpty {
                                Text("iOS \(min)+").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let changelog = v.changelog, !changelog.isEmpty {
                            Text(changelog).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    Button("button.Install") {
                        installs.start(app: app, version: v)
                    }
                    .font(.caption)
                }
                .padding(.leading, 56)
                Divider()
            }
        }
    }

    private var metadataText: String {
        let installed = installs.installedVersion(for: app.bundleIdentifier)
        var parts: [String] = []
        if let installed {
            parts.append("Installed \(installed.version)")
        }
        if let latest = installs.latestCompatible(app) {
            var s = latest.version
            if let build = latest.buildVersion, !build.isEmpty { s += " (\(build))" }
            parts.append(s)
        } else {
            parts.append(app.bundleIdentifier)
            return parts.joined(separator: " • ")
        }
        parts.append(app.bundleIdentifier)
        return parts.joined(separator: " • ")
    }

    private var subtitleText: String? {
        if let subtitle = app.subtitle, !subtitle.isEmpty { return subtitle }
        return app.developerName
    }
}

private struct SourceFeedIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "app.dashed")
                            .resizable().scaledToFit()
                            .padding(6)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

private struct ManageSourcesSheet: View {
    @Bindable var store: AppSourcesStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var editingItem: SourceItem?
    @State private var editURLText = ""
    @State private var editNameText = ""
    @State private var editError: String?
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("sources.manage.current") {
                    if store.sources.isEmpty {
                        Text("sources.empty.title")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.sources) { item in
                            HStack(spacing: 10) {
                                SourceFeedIcon(url: item.source?.iconURL)
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName).bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    editingItem = item
                                    editURLText = item.url.absoluteString
                                    editNameText = item.customName ?? ""
                                    editError = nil
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("sources.edit")
                                Button(role: .destructive) {
                                    store.removeSource(item)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("sources.remove")
                            }
                        }
                    }
                }
                Section("sources.manage.manual") {
                    TextField("https://example.com/source.json", text: $urlText)
                        .disableAutocorrection(true)
                    if let addError {
                        Text(addError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Button {
                        attemptAdd()
                    } label: {
                        if isAdding {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("sources.add").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }
                Section("sources.manage.reset") {
                    Text("sources.manage.resetHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("sources.manage.resetAll", role: .destructive) {
                        showResetConfirm = true
                    }
                    .disabled(store.sources.isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("button.Close") { dismiss() }
            }
        }
        .sheet(item: $editingItem) { item in
            VStack(spacing: 12) {
                Text("sources.edit.title")
                    .font(.headline)
                TextField("https://example.com/source.json", text: $editURLText)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                TextField("sources.edit.name", text: $editNameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                if let editError {
                    Text(editError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("button.Cancel") { editingItem = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("button.Save") { attemptEdit() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(editURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }
            }
            .padding()
            .frame(width: 380)
        }
        .alert("sources.manage.resetTitle", isPresented: $showResetConfirm) {
            Button("sources.manage.resetAll", role: .destructive) {
                store.resetAllSources()
                showResetConfirm = false
            }
            Button("button.Cancel", role: .cancel) { showResetConfirm = false }
        } message: {
            Text("sources.manage.resetMessage")
        }
    }

    private func attemptAdd() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAdding else { return }
        isAdding = true
        addError = nil
        Task {
            let error = await store.addSource(from: trimmed)
            if error == nil {
                urlText = ""
                dismiss()
            } else {
                addError = error
            }
            isAdding = false
        }
    }

    private func attemptEdit() {
        guard let item = editingItem else { return }
        let trimmedURL = editURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        isAdding = true
        editError = nil
        Task {
            // Rename by stable pre-edit identity, then re-resolve for the URL change.
            store.renameSource(item, to: editNameText)
            guard let current = store.sources.first(where: { $0.url == item.url }) else {
                editingItem = nil
                isAdding = false
                return
            }
            if current.url.absoluteString != trimmedURL,
               let error = await store.updateSource(current, to: trimmedURL) {
                editError = error
            } else {
                editingItem = nil
            }
            isAdding = false
        }
    }
}
