//
//  BypassesPane.swift
//  Ophanim
//

import SwiftUI

struct BypassesView: View {
    @Bindable var settings: AppSettings
    @Binding var hasGalgal: Bool?
    @Binding var task: BlockingTask
    @AppStorage("settings.settings.chainGuard") private var chainGuard = false
    @AppStorage("settings.settings.chainGuardDebugging") private var chainGuardDebugging = false
    @AppStorage("settings.settings.bypass") private var bypass = false
    @State private var hasIntrospection: Bool
    @State private var hasIosFrameworks: Bool
    @State private var appCategory: LSApplicationCategoryType = .none
    @State private var signingCategory = false

    var app: HostedApp

    init(settings: AppSettings,
         hasGalgal: Binding<Bool?>,
         task: Binding<BlockingTask>,
         app: HostedApp) {
        self._settings = Bindable(wrappedValue: settings)
        self._hasGalgal = hasGalgal
        self._task = task
        self.app = app

        let lsEnvironment = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        self.hasIntrospection = lsEnvironment.contains(HostedApp.introspection)
        self.hasIosFrameworks = lsEnvironment.contains(HostedApp.iosFrameworks)
    }

    private let jbCols = [GridItem(.flexible(), alignment: .leading),
                          GridItem(.flexible(), alignment: .leading)]

    /// Toggle binding for a single jailbreak detector (by ObjC class id) in the allowlist.
    private func jbBind(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.settings.jailbreakBypasses.contains(id) },
                set: { on in
                    var set = settings.settings.jailbreakBypasses
                    if on {
                        if !set.contains(id) { set.append(id) }
                    } else {
                        set.removeAll { $0 == id }
                    }
                    settings.settings.jailbreakBypasses = set
                })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Application Type") {
                    HStack {
                        Text("settings.applicationCategoryType")
                        if signingCategory {
                            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                        }
                        Spacer()
                        Picker("", selection: $appCategory) {
                            ForEach([.none] + LSApplicationCategoryType.allCases.filter { $0 != .none },
                                    id: \.rawValue) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                        .frame(width: 250)
                        .help("settings.applicationCategoryType.help")
                        .onChange(of: appCategory) { _, _ in
                            signingCategory = true
                            app.info.applicationCategoryType = appCategory
                            let executable = app.executable
                            Task.detached {
                                do {
                                    try await Shell.signApp(executable)
                                } catch {
                                    Log.shared.error(error)
                                }
                                Task { @MainActor in signingCategory = false }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Jailbreak / Root Detection") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bypass each SDK's detector individually (\(settings.settings.jailbreakBypasses.count)/\(JBBypassCatalog.all.count))")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Select All") {
                                settings.settings.jailbreakBypasses = JBBypassCatalog.allIDs
                            }
                            Button("None") {
                                settings.settings.jailbreakBypasses = []
                            }
                        }
                        LazyVGrid(columns: jbCols, alignment: .leading, spacing: 2) {
                            ForEach(JBBypassCatalog.all, id: \.id) { entry in
                                Toggle(entry.label, isOn: jbBind(entry.id))
                                    .help(entry.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Keychain Emulation (ChainGuard)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.chainGuard.enable", isOn: $settings.settings.chainGuard)
                            .help("settings.chainGuard.help")
                            .disabled(!(hasGalgal ?? true))
                        Toggle("settings.chainGuard.debugging", isOn: $settings.settings.chainGuardDebugging)
                            .disabled(!settings.settings.chainGuard)
                            .help("settings.chainGuard.debugging.help")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("TLS / Certificate Pinning") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Bypass certificate pinning (force-accept)",
                               isOn: $settings.settings.ophanim.bypassPinning)
                            .disabled(!(hasGalgal ?? true))
                            .help("Forces SecTrust evaluation to succeed so app-level pinning "
                                  + "(TrustKit / AFNetworking / Alamofire / custom URLSession validators) "
                                  + "can't reject the chain. Does not reach pinning inside a "
                                  + "statically-linked TLS stack (e.g. Cronet).")
                        Text("Hooks SecTrustEvaluateWithError - covers SecTrust-based pinning (most apps), "
                             + "not in-process TLS stacks like Cronet. Pinning checks are logged under the "
                             + "Network capture category.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Injected Libraries") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.toggle.introspection", isOn: $hasIntrospection)
                            .help("settings.toggle.introspection.help")
                            .toggleStyle(.async($task, role: .introspection))
                        Toggle("settings.toggle.iosFrameworks", isOn: $hasIosFrameworks)
                            .help("settings.toggle.iosFrameworks.help")
                            .toggleStyle(.async($task, role: .iosFrameworks))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("settings.customPlugins.title") {
                    CustomDylibView(app: app, settings: settings, hasGalgal: $hasGalgal)
                }

                GroupBox("Compatibility") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.toggle.rootWorkDir", isOn: $settings.settings.rootWorkDir)
                            .disabled(!(hasGalgal ?? true))
                            .help("settings.toggle.rootWorkDir.help")
                        Toggle("settings.toggle.limitMotionUpdateFrequency",
                               isOn: $settings.settings.limitMotionUpdateFrequency)
                            .disabled(!(hasGalgal ?? true))
                            .help("settings.toggle.limitMotionUpdateFrequency.help")
                        Toggle("settings.toggle.blockSleepSpamming", isOn: $settings.settings.blockSleepSpamming)
                            .help("settings.toggle.blockSleepSpamming.help")
                        Toggle("settings.toggle.checkMicPermissionSync", isOn: $settings.settings.checkMicPermissionSync)
                            .help("settings.toggle.checkMicPermissionSync.help")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .onAppear { appCategory = app.info.applicationCategoryType }
        .onChange(of: hasIntrospection) { _, _ in
            task = .introspection
            Task {
                _ = await app.changeDyldLibraryPath(set: hasIntrospection, path: HostedApp.introspection)
                task = .none
            }
        }
        .onChange(of: hasIosFrameworks) { _, _ in
            task = .iosFrameworks
            Task {
                _ = await app.changeDyldLibraryPath(set: hasIosFrameworks, path: HostedApp.iosFrameworks)
                task = .none
            }
        }
    }
}
