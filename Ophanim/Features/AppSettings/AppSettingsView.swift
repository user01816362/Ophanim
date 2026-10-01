//
//  AppSettingsView.swift
//  Ophanim
//
//  Created by Isaac Marovitz on 14/08/2022.
//

import SwiftUI
import DataCache

struct AppSettingsView: View {
    @Environment(\.dismiss) var dismiss

    @Bindable var viewModel: AppSettingsVM

    @Binding var showKeymapSheet: Bool

    /// The visible pane. Owned by the settings window (toolbar selection), not local state.
    @Binding var selectedTab: SettingsTab

    /// Called when the view asks to close (OK / reset / keymap buttons). The window manager
    /// supplies this; the sheet-era `dismiss()` below is kept as a no-op fallback.
    var onClose: (() -> Void)? = nil
    @State var resetSettingsCompletedAlert = false
    @State var closeView = false
    @State var appIcon: NSImage?
    @State var hasGalgal: Bool?
    @State var hasAlias: Bool?

    @State private var currentTask = BlockingTask.none
    @State private var cache = DataCache.instance

    var body: some View {
        VStack {
            HStack {
                Group {
                    if let image = appIcon {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(width: 60, height: 60)
                    }
                }
                .cornerRadius(10)
                .shadow(radius: 1)
                .frame(width: 33, height: 33)

                VStack {
                    HStack {
                        Text(String(
                            format:
                                NSLocalizedString("settings.title", comment: ""),
                            viewModel.app.name))
                            .font(.title2).bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }

                    let noGalgalWarning = Image(systemName: "exclamationmark.triangle")
                    let warning = NSLocalizedString("settings.noGalgal", comment: "")

                    if !(hasGalgal ?? true) {
                        HStack {
                            Text("\(noGalgalWarning) \(warning)")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                    }
                }
            }
            .task(priority: .userInitiated) {
                appIcon = cache.readImage(forKey: viewModel.app.info.bundleIdentifier)
            }

            // Panes switch from the window toolbar (HIG settings window). A TabView was
            // tried here and reverted: inside a sheet macOS collapses it into a ~40px
            // segmented control that truncates every label.
            Group {
                switch selectedTab {
                case .graphics:
                    GraphicsView(settings: viewModel.settings, app: viewModel.app)
                        .disabledWhenNoGalgal(hasGalgal)
                case .bypasses:
                    BypassesView(settings: viewModel.settings,
                                 hasGalgal: $hasGalgal,
                                 task: $currentTask,
                                 app: viewModel.app)
                        .disabledWhenNoGalgal(hasGalgal)
                case .hacking:
                    InstrumentationView(settings: viewModel.settings, app: viewModel.app)
                case .keymapping:
                    KeymappingView(settings: viewModel.settings)
                        .disabledWhenNoGalgal(hasGalgal)
                case .info:
                    InfoView(info: viewModel.app.info, hasGalgal: (hasGalgal ?? true))
                case .container:
                    ContainerView(app: viewModel.app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button {
                    currentTask = .galgal
                    Task(priority: .userInitiated) {
                        if hasGalgal ?? true {
                            await Galgal.removeFromApp(viewModel.app.executable)
                        } else {
                            do {
                                try await Galgal.installInIPA(viewModel.app.executable)
                            } catch {
                                Log.shared.error(error)
                            }
                        }
                        Task { @MainActor in
                            AppsVM.shared.filteredApps = []
                            AppsVM.shared.fetchApps()
                        }
                        currentTask = .none
                        closeView.toggle()
                    }
                } label: {
                    Text((hasGalgal ?? true) ? "settings.removeGalgal" : "alert.install.injectGalgal")
                        .opacity(currentTask == .galgal ? 0 : 1)
                        .overlay {
                            if currentTask == .galgal { ProgressView().scaleEffect(0.5) }
                        }
                }
                Spacer()
                Button("settings.resetSettings") {
                    resetSettingsCompletedAlert.toggle()
                    viewModel.app.settings.reset()
                    closeView.toggle()
                }
                Button("hostedapp.keymap") {
                    closeView.toggle()
                    showKeymapSheet.toggle()
                }
                Button("button.OK") {
                    closeView.toggle()
                }
                .tint(.accentColor)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(currentTask != .none)
        .onChange(of: resetSettingsCompletedAlert) { _, _ in
            ToastVM.shared.showToast(
                toastType: .notice,
                toastDetails: NSLocalizedString("settings.resetSettingsCompleted", comment: ""))
        }
        .onChange(of: closeView) { _, _ in
            onClose?()
            dismiss()
        }
        .task(priority: .background) {
            hasGalgal = viewModel.app.hasGalgal()
            hasAlias = viewModel.app.hasAlias()
        }
        .padding()
        // In the settings window the NSWindow owns the size (840x640 content); this floor only
        // keeps panes usable if the view is ever hosted elsewhere.
        .frame(minWidth: 780, minHeight: 560)
        
        .buttonStyle(.bordered)
    }
}
