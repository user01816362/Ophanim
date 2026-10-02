//
//  KeyCoverViews.swift
//  Ophanim
//
//  KeyCover unlock prompt: validates the master password into memory so a touched
//  locked chain can decrypt. Shown on demand, not at launch.
//

import SwiftUI

/// Master-password prompt for unlocking a chain. A valid password stays in memory
/// (Smart Unlock); a wrong one only flags the field, never dismisses.
struct KeyCoverUnlockingPrompt: View {
    @State private var password = ""
    @State private var passwordError = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "lock")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text("keycover.unlockPrompt.title")
                    .padding()
            }
            .padding()
                SecureField("keycover.masterPassword", text: $password)
                    .padding()
                if passwordError {
                    Text("keycover.error.incorrectPassword")
                        .foregroundColor(.red)
                        .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("button.Cancel") {
                    KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.Unlock") {
                    unlock()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    /// Validates the typed password; on success keeps it in memory for later chains.
    func unlock() {
        if KeyCoverPassword.shared.validatePassword(password) {
            // if Smart Unlock is enabled, store the masterKey
            KeyCover.shared.keyCoverPlainTextKey = password
        } else {
            passwordError = true
            return
        }
        KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown = false
    }
}
