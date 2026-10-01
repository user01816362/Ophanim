//
//  CustomDylibView.swift
//  Ophanim
//

import SwiftUI
import AppKit

struct CustomDylibView: View {
    var app: HostedApp
    @Bindable var settings: AppSettings
    @Binding var hasGalgal: Bool?
    @Bindable private var vm: TweakLibraryVM
    @State private var showWarning = false
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @AppStorage("hasShownCustomPluginWarning") private var hasShownWarning = false

    init(app: HostedApp, settings: AppSettings, hasGalgal: Binding<Bool?>) {
        self.app = app
        self.settings = settings
        self._hasGalgal = hasGalgal
        _vm = Bindable(wrappedValue: TweakLibraryVM(app: app, settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tweak Folder Path & Selector
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: vm.isUsingCustomFolder ? "folder.badge.gearshape" : "folder")
                        .foregroundStyle(Color.accentColor)
                    Text(vm.isUsingCustomFolder ? "Custom Tweak Folder:" : "Default Tweak Folder:")
                        .font(.caption).bold()
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vm.activeStoreURL.path)
                    }
                    .buttonStyle(.link)
                    .font(.caption)

                    Button("Change Folder…") {
                        vm.chooseCustomFolder()
                    }
                    .font(.caption)
                    .disabled(vm.isProcessing)

                    if vm.isUsingCustomFolder {
                        Button("Reset") {
                            vm.resetCustomFolder()
                        }
                        .font(.caption)
                        .disabled(vm.isProcessing)
                    }
                }

                if vm.isUsingCustomFolder && !vm.isCustomFolderAccessible {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Custom folder is unreachable or disconnected. Using default folder.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Text(vm.activeStoreURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(6)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)

            // Header Toolbar
            HStack {
                Text("Installed Tweaks (\(vm.items.filter(\.isEnabled).count)/\(vm.items.count) enabled)")
                    .font(.headline)
                Spacer()
                if vm.isProcessing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Button {
                    newFolderName = ""
                    showNewFolderSheet = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .font(.caption)
                .disabled(vm.isProcessing)

                Button {
                    if hasShownWarning {
                        vm.selectAndAddTweak()
                    } else {
                        showWarning = true
                    }
                } label: {
                    Label("settings.customPlugins.add", systemImage: "plus")
                }
                .font(.caption)
                .disabled(vm.isProcessing)
            }

            // Tweak Item List
            if vm.items.isEmpty {
                VStack(alignment: .center, spacing: 4) {
                    Text("settings.customPlugins.empty")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Import .dylib, .framework, or tweak folders to inject into this app.")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(vm.items) { item in
                        HStack(spacing: 8) {
                            if item.isFolder {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else if item.isFramework {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundStyle(.purple)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayName)
                                    .font(.system(.body, design: .monospaced))
                                Text(item.isFolder ? "Folder (Recursively loaded)" : (item.isFramework ? "Framework Bundle" : "Mach-O Dylib"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .opacity(item.isEnabled ? 1.0 : 0.45)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { item.isEnabled },
                                set: { vm.toggleEnabled(item: item, enabled: $0) }
                            ))
                            .labelsHidden()
                            .disabled(vm.isProcessing)
                            .help(item.isEnabled ? "Click to disable" : "Click to enable")

                            Button {
                                vm.removeItem(item)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isProcessing)
                            .help("Delete")
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .disabledWhenNoGalgal(hasGalgal)
        .onAppear {
            Task { await vm.reloadItems() }
        }
        .alert("settings.customPlugins.warningTitle", isPresented: $showWarning) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.customPlugins.warningConfirm", role: .destructive) {
                hasShownWarning = true
                vm.selectAndAddTweak()
            }
        } message: {
            Text("settings.customPlugins.warningMessage")
        }
        .sheet(isPresented: $showNewFolderSheet) {
            VStack(spacing: 12) {
                Text("Create New Tweak Folder")
                    .font(.headline)
                TextField("Folder Name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                HStack {
                    Button("button.Cancel") { showNewFolderSheet = false }
                    Button("Create") {
                        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty,
                              !name.hasPrefix("."),
                              !name.contains("/"),
                              !name.contains("\\"),
                              !name.contains(":"),
                              !name.contains("..") else {
                            ToastVM.shared.showToast(toastType: .error,
                                                     toastDetails: "Invalid folder name. Slashes, colons, and leading dots are not allowed.")
                            showNewFolderSheet = false
                            return
                        }
                        vm.createSubfolder(named: name)
                        showNewFolderSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }
}
