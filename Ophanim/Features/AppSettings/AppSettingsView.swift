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

            TabView {
                GraphicsView(settings: viewModel.settings, app: viewModel.app)
                    .tabItem {
                        Text("settings.tab.graphics")
                    }
                    .disabled(!(hasGalgal ?? true))
                BypassesView(settings: viewModel.settings,
                             hasGalgal: $hasGalgal,
                             task: $currentTask,
                             app: viewModel.app)
                    .tabItem {
                        Text("settings.tab.bypasses")
                    }
                    .disabled(!(hasGalgal ?? true))
                InstrumentationView(settings: viewModel.settings, app: viewModel.app)
                    .tabItem {
                        Text("Hacking")
                    }
                KeymappingView(settings: viewModel.settings)
                    .tabItem {
                        Text("settings.tab.km")
                    }
                    .disabled(!(hasGalgal ?? true))
                ContainerView(app: viewModel.app)
                    .tabItem {
                        Text("settings.tab.container")
                    }
                InfoView(info: viewModel.app.info, hasGalgal: (hasGalgal ?? true))
                    .tabItem {
                        Text("settings.tab.info")
                    }
            }
            .frame(minWidth: 500, minHeight: 250)
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
            dismiss()
        }
        .task(priority: .background) {
            hasGalgal = viewModel.app.hasGalgal()
            hasAlias = viewModel.app.hasAlias()
        }
        .padding()
        .frame(width: 720, height: 470)
        
        .buttonStyle(.bordered)
    }
}
