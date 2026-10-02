//
//  KeyCoverSettings.swift
//  Ophanim
//
//  KeyCover settings tab (legacy, hidden while KeyCover is hard-disabled): status,
//  enable/reset, lock-all, password change, startup prompt.
//

import SwiftUI

/// KeyCover master-key mode: off, app-generated password, or user-provided password.
enum KeyCoverStatus: String, Codable, Hashable {
    case disabled
    case selfGeneratedPassword
    case userProvidedPassword
}

/// Persisted KeyCover prefs (mode + startup prompt). First access may be off-main
/// (MCP transport), so the shared init hops to main for @AppStorage.
class KeyCoverPreferences: NSObject, ObservableObject {
    nonisolated(unsafe) static var shared: KeyCoverPreferences = {
        // @AppStorage init is MainActor-isolated; first access may come from a
        // background thread (MCP transport), so hop to main instead of assuming it.
        if Thread.isMainThread { KeyCoverPreferences() } else { DispatchQueue.main.sync { KeyCoverPreferences() } }
    }()

    @AppStorage("keyCoverEnabled") var keyCoverEnabled: KeyCoverStatus = KeyCoverStatus.disabled
    @AppStorage("promptForKeyCoverPasswordAtLaunch") var promptForKeyCoverPasswordAtLaunch = true
}

/// KeyCover settings form (legacy, hidden): status, enable/reset (Option = force
/// reset), lock-all, password change, startup prompt.
struct KeyCoverSettings: View {

    @State private var keyCoverInitialSetupShown = false
    @State private var keyCoverUpdatePasswordShown = false
    @State private var keyCoverRemovalViewShown = false

    @ObservedObject var keyCoverPreferences = KeyCoverPreferences.shared
    @Bindable var keyCoverObserved = KeyCoverObservable.shared

    @Bindable var modifierKeyObserver = ModifierKeyObserver.shared

    var body: some View {
        VStack {
            HStack {
                HStack {
                    Text("keycover.status.title")
                    Text(keyCoverObserved.keyCoverEnabled ?
                             KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword ?
                             "keycover.status.managedPassword" : "keycover.status.userPassword"
                         : "state.disabled")
                        .foregroundColor(keyCoverObserved.keyCoverEnabled ? .green : .none)
                    Spacer()
                }
                Spacer()
                Button(keyCoverObserved.keyCoverEnabled ? "button.Reset" : "button.Enable") {
                    if keyCoverObserved.keyCoverEnabled {
                        if modifierKeyObserver.isOptionKeyPressed {
                            KeyCoverPassword.shared.forceResetKeyCoverPassword()
                        } else {
                            keyCoverRemovalViewShown = true
                        }
                    } else {
                        keyCoverInitialSetupShown = true
                    }
                }
                .foregroundColor((keyCoverObserved.keyCoverEnabled
                                 && modifierKeyObserver.isOptionKeyPressed)
                                    ? .red : .none)
            }
            .padding()
            Spacer()
            HStack {
                VStack(alignment: .leading) {
                    Text("keycover.status.chainCount")
                    Text(String(format: NSLocalizedString("keycover.status.unlockedCount %@ %@", comment: ""),
                                "\(keyCoverObserved.unlockedCount)",
                                "\(keyCoverObserved.keychains.count)"))
                }
                Spacer()
                Button("keycover.button.lockAll") {
                    KeyCover.shared.lockAllChainsAsync()
                }
                .disabled(!keyCoverObserved.keyCoverEnabled)
            }
            .padding()
            HStack {
                Spacer()
                Button("keycover.button.changePassword") {
                    keyCoverUpdatePasswordShown = true
                }
                .disabled(!keyCoverObserved.keyCoverEnabled)
                Spacer()
            }
            .padding()
            VStack(alignment: .leading) {
                Toggle("keycover.toggle.startupPrompt", isOn: $keyCoverPreferences.promptForKeyCoverPasswordAtLaunch)
                    .help("keycover.toggle.startupPrompt.help")
                Spacer()
            }
            .padding()
        }
        .frame(width: 600, height: 300)
        .sheet(isPresented: $keyCoverInitialSetupShown) {
            KeyCoverInitialSetupView(isPresented: $keyCoverInitialSetupShown)
        }
        .sheet(isPresented: $keyCoverUpdatePasswordShown) {
            KeyCoverUpdatePasswordView(isPresented: $keyCoverUpdatePasswordShown)
        }
        .sheet(isPresented: $keyCoverRemovalViewShown) {
            KeyCoverRemovalView(isPresented: $keyCoverRemovalViewShown)
        }
    }
}

struct KeyCoverSettings_Previews: PreviewProvider {
    static var previews: some View {
        KeyCoverSettings()
    }
}
