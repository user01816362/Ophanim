//
//  KeymappingPane.swift
//  Ophanim
//

import SwiftUI

struct KeymappingView: View {
    @ObservedObject var settings: AppSettings
    @AppStorage("settings.settings.keymapping") private var keymapping = false
    @AppStorage("settings.settings.noKMOnInput") private var noKMOnInput = false
    @AppStorage("settings.settings.enableScrollWheel") private var enableScrollWheel = false
    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Toggle("settings.toggle.km", isOn: $settings.settings.keymapping)
                        .help("settings.toggle.km.help")
                    Spacer()
                    Toggle("settings.toggle.autoKM", isOn: $settings.settings.noKMOnInput)
                        .help("settings.toggle.autoKM.help")
                }
                HStack {
                    Toggle("settings.toggle.enableScrollWheel", isOn: $settings.settings.enableScrollWheel)
                        .help("settings.toggle.enableScrollWheel.help")
                    Spacer()
                }
                HStack {
                    Toggle("settings.toggle.disableBuiltinMouse", isOn: $settings.settings.disableBuiltinMouse)
                        .help("settings.toggle.disableBuiltinMouse.help")
                    Spacer()
                }
                HStack {
                    Text(String(
                        format: NSLocalizedString("settings.slider.mouseSensitivity", comment: ""),
                        settings.settings.sensitivity))
                    Spacer()
                    Slider(value: $settings.settings.sensitivity, in: 0...100, label: { EmptyView() })
                        .frame(width: 250)
                        .disabled(!settings.settings.keymapping)
                        .help("settings.slider.mouseSensitivity.help")
                }
                Spacer()
            }
            .padding()
        }
    }
}
