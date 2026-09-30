//
//  MainView.swift
//  Ophanim
//

import SwiftUI

struct MainView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.controlActiveState) var controlActiveState

    @Environment(AppsVM.self) var apps
    @Environment(AppIntegrity.self) var integrity

    @Bindable var keyCoverObserved = KeyCoverObservable.shared

    @Binding public var isSigningSetupShown: Bool

    @State private var selectedBackgroundColor: Color = Color.accentColor
    @State private var selectedTextColor: Color = Color.black

    var body: some View {
        // The app library is the whole window: with IPA sources removed there is nothing else to
        // navigate to, so the sidebar is gone and the library renders directly.
        AppLibraryView(selectedBackgroundColor: $selectedBackgroundColor,
                       selectedTextColor: $selectedTextColor)
            .onChange(of: colorScheme) { _, scheme in
                updateSelectionColors(scheme: scheme)
            }
            .onChange(of: controlActiveState) { _, state in
                if state == .inactive {
                    if colorScheme == .light {
                        selectedTextColor = .black
                    }
                    selectedBackgroundColor = .secondary
                } else {
                    if colorScheme == .light {
                        selectedTextColor = .white
                    }
                    selectedBackgroundColor = .accentColor
                }
            }
            .onAppear {
                updateSelectionColors(scheme: colorScheme)
            }
            .toastOverlay {
                ToastView()
                    .environment(ToastVM.shared)
                    .environment(InstallVM.shared)
            }
            .alert("alert.moveAppToApplications.title",
                   isPresented: Binding(
                       get: { integrity.integrityOff },
                       set: { integrity.integrityOff = $0 }
                   )) {
                Button("alert.moveAppToApplications.move", role: .cancel) {
                    integrity.moveToApps()
                }
                .tint(.accentColor)
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("alert.moveAppToApplications.subtitle")
            }
            .sheet(isPresented: $isSigningSetupShown) {
                SignSetupView(isSigningSetupShown: $isSigningSetupShown)
            }
            .sheet(isPresented: $keyCoverObserved.isKeyCoverUnlockingPromptShown) {
                KeyCoverUnlockingPrompt()
            }
            .frame(minWidth: 675, minHeight: 330)
            .ophanimTheme()
    }

    private func updateSelectionColors(scheme: ColorScheme) {
        if scheme == .dark {
            selectedTextColor = .white
        } else {
            selectedTextColor = controlActiveState == .inactive ? .black : .white
        }
    }
}

struct MainView_Previews: PreviewProvider {
    @State static var isSigningSetupShown = true

    static var previews: some View {
        MainView(isSigningSetupShown: $isSigningSetupShown)
            .environment(InstallVM.shared)
            .environment(AppsVM.shared)
            .environment(AppIntegrity())
    }
}
