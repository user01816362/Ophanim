//
//  GraphicsPane.swift
//  Ophanim
//

import SwiftUI

struct GraphicsView: View {
    @Bindable var settings: AppSettings
    var app: HostedApp
    @State var customWidth = 1920
    @State var customHeight = 1080
    @State var showResolutionWarning = false
    static var number: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }

    @State var customScaler = 2.0
    static var fractionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        formatter.decimalSeparator = "."
        return formatter
    }

    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Text("settings.picker.iosDevice")
                    Spacer()
                    Picker("", selection: $settings.settings.iosDeviceModel) {
                        // -- iPad Pro (M1-M5; RAM = highest tier per model) --
                        Text("iPad Pro 12.9-inch (5th generation) | M1 | 16GB").tag("iPad13,8")
                        Text("iPad Pro 12.9-inch (6th generation) | M2 | 16GB").tag("iPad14,5")
                        Text("iPad Pro 13-inch (M4) | M4 | 16GB").tag("iPad16,5")
                        Text("iPad Pro 13-inch (M5) | M5 | 12GB").tag("iPad17,3")
                        Divider()
                        // -- iPhone 16 series (all 8GB) --
                        Text("iPhone 16 Pro | A18 Pro | 8GB").tag("iPhone17,1")
                        Text("iPhone 16 Pro Max | A18 Pro | 8GB").tag("iPhone17,2")
                        Text("iPhone 16 | A18 | 8GB").tag("iPhone17,3")
                        Text("iPhone 16 Plus | A18 | 8GB").tag("iPhone17,4")
                        Text("iPhone 16e | A18 | 8GB").tag("iPhone17,5")
                        Divider()
                        // -- iPhone 17 series --
                        Text("iPhone 17 Pro | A19 Pro | 12GB").tag("iPhone18,1")
                        Text("iPhone 17 Pro Max | A19 Pro | 12GB").tag("iPhone18,2")
                        Text("iPhone 17 | A19 | 8GB").tag("iPhone18,3")
                        Text("iPhone Air | A19 Pro | 12GB").tag("iPhone18,4")
                        Text("iPhone 17e | A19 | 8GB").tag("iPhone18,5")
                        Divider()
                        // -- iPhone 18 series (identifiers verified; RAM leak-grade) --
                        Text("iPhone 18 Pro | A20 Pro | 12GB").tag("iPhone19,2")
                        Text("iPhone 18 Pro Max | A20 Pro | 12GB").tag("iPhone19,3")
                        Text("iPhone Duo | A20 Pro | 12GB").tag("iPhone19,4")
                    }
                    .frame(width: 250)
                    .help("settings.picker.iosDevice.help")
                }
                HStack {
                    if showResolutionWarning {
                        Spacer()
                        let highResIcon = Image(systemName: "exclamationmark.triangle")
                        let warning = NSLocalizedString("settings.highResolution", comment: "")

                        Text("\(highResIcon) \(warning)")
                            .font(.caption)
                    } else {
                        Spacer()
                    }
                }
                HStack {
                    Text("settings.picker.adaptiveRes")
                    Spacer()
                    Picker("", selection: $settings.settings.resolution) {
                        Text("settings.picker.adaptiveRes.0").tag(0)
                        Text("settings.picker.adaptiveRes.1").tag(1)
                        Text("1080p").tag(2)
                        Text("1440p").tag(3)
                        Text("4K").tag(4)
                        Text("settings.picker.adaptiveRes.5").tag(5)
                        Text("settings.picker.adaptiveRes.6").tag(6)
                    }
                    .frame(width: 250, alignment: .leading)
                    .help("settings.picker.adaptiveRes.help")
                }
                HStack {
                    if settings.settings.resolution == 5 {
                        Text(NSLocalizedString("settings.text.customWidth", comment: "") + ":")
                        Stepper {
                            TextField(
                                "settings.text.customWidth",
                                value: $customWidth,
                                formatter: GraphicsView.number,
                                onCommit: {
                                    Task { @MainActor in
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                })
                                .frame(width: 125)
                        }
                        onIncrement: { customWidth += 1 }
                        onDecrement: { customWidth -= 1 }
                        Spacer()
                        Text(NSLocalizedString("settings.text.customHeight", comment: "") + ":")
                        Stepper {
                            TextField(
                                "settings.text.customHeight",
                                value: $customHeight,
                                formatter: GraphicsView.number,
                                onCommit: {
                                    Task { @MainActor in
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                })
                                .frame(width: 125)
                        } onIncrement: {
                            customHeight += 1
                        } onDecrement: {
                            customHeight -= 1
                        }
                    } else if settings.settings.resolution >= 2 && settings.settings.resolution <= 4 {
                        Text("settings.picker.aspectRatio")
                        Spacer()
                        Picker("", selection: $settings.settings.aspectRatio) {
                            Text("4:3").tag(0)
                            Text("16:9").tag(1)
                            Text("16:10").tag(2)
                        }
                        .help("settings.picker.aspectRatio.help")
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    } else if settings.settings.resolution == 6 {
                        Text("settings.picker.aspectRatio")
                        VStack(alignment: .trailing) {
                            Picker("", selection: $settings.settings.resizableAspectRatioType) {
                                Text("settings.picker.aspectRatio.free").tag(0)
                                Text("settings.picker.aspectRatio.custom").tag(1)
                                Text("4:3").tag(2)
                                Text("16:9").tag(3)
                                Text("16:10").tag(4)
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            if settings.settings.resizableAspectRatioType == 1 {
                                HStack {
                                    TextField("", value: $settings.settings.resizableAspectRatioWidth,
                                              formatter: GraphicsView.number)
                                    .frame(width: 110)
                                    Text(":")
                                    TextField("", value: $settings.settings.resizableAspectRatioHeight,
                                              formatter: GraphicsView.number)
                                    .frame(width: 110)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if settings.settings.resolution == 1 {
                        let width = Int(NSScreen.main?.frame.width ?? 1920)
                        let height = getHeightForNotch(width, Int(NSScreen.main?.frame.height ?? 1080))
                        Text("settings.text.detectedResolution")
                        Spacer()
                        Text("\(width) x \(height)")
                    } else {
                        Spacer()
                    }
                }
                HStack {
                    Text("settings.picker.scaler")
                        .help("settings.picker.scaler.help")
                    Spacer()
                    Stepper {
                        TextField(
                            "settings.text.scaler",
                            value: $customScaler,
                            formatter: GraphicsView.fractionFormatter,
                            onCommit: {
                                Task { @MainActor in NSApp.keyWindow?.makeFirstResponder(nil) }
                            })
                            .frame(width: 125)
                    } onIncrement: {
                        customScaler += 0.1
                    } onDecrement: {
                        if customScaler > 0.5 { customScaler -= 0.1 }
                    }
                }
                VStack(alignment: .leading) {
HStack {
    Toggle("settings.picker.windowFix", isOn: $settings.settings.inverseScreenValues)
        .help("settings.picker.windowFix.help")
        .onChange(of: settings.settings.inverseScreenValues) { _, _ in
            settings.settings.windowFixMethod = 0
        }
    Spacer()
    // Dropdown to choose fix method
    Picker("", selection: $settings.settings.windowFixMethod) {
        Text("settings.picker.windowFixMethod.0").tag(0)
        Text("settings.picker.windowFixMethod.1").tag(1)
    }
    .frame(alignment: .leading)
    .help("settings.picker.windowFixMethod.help")
    .disabled(!settings.settings.inverseScreenValues)
}
Spacer()
                    HStack {
                        Text("settings.settings.displayRotation")
                        Spacer()
                        Picker("", selection: $settings.settings.displayRotation) {
                            Text("settings.settings.displayRotation.default").tag(0)
                            Text("settings.settings.displayRotation.portrait").tag(1)
                            Text("settings.settings.displayRotation.landscapeRight").tag(2)
                            Text("settings.settings.displayRotation.portraitUpsideDown").tag(3)
                            Text("settings.settings.displayRotation.flipFix").tag(4)
                        }
                        .frame(alignment: .leading)
                        .help("settings.settings.displayRotation.help")
                    }
                    Spacer()
                    Toggle("settings.toggle.floatingWindow", isOn: $settings.settings.floatingWindow)
                        .help("settings.toggle.floatingWindow.help")
                    Spacer()
                    Toggle("settings.toggle.disableDisplaySleep", isOn: $settings.settings.disableTimeout)
                        .help("settings.toggle.disableDisplaySleep.help")
                    Spacer()
                    Toggle("settings.toggle.hideTitleBar", isOn: $settings.settings.hideTitleBar)
                        .help("settings.toggle.hideTitleBar.help")
                    Spacer()
Toggle("settings.toggle.hud", isOn: $settings.settings.metalHUD)
    .help("Show Apple's Metal performance HUD (FPS/GPU) overlay for this app.")
Spacer()
                }
                Spacer()
            }
            .padding()
            .onAppear {
                customWidth = settings.settings.windowWidth
                customHeight = settings.settings.windowHeight
                customScaler = settings.settings.customScaler
            }
            .onChange(of: settings.settings.resolution) { _, _ in
                setResolution()
            }
            .onChange(of: settings.settings.aspectRatio) { _, _ in
                setResolution()
            }
            .onChange(of: customWidth) { _, _ in
                setResolution()
            }
            .onChange(of: customHeight) { _, _ in
                setResolution()
            }
            .onChange(of: customScaler) { _, _ in
                setResolution()
            }
            .onChange(of: settings.settings.resizableAspectRatioType) { _, _ in
                setAspectRatioForResizableWindow()
            }
        }
    }

    func setResolution() {
        let screenW = Int(NSScreen.main?.frame.width ?? 1920)
        let screenH = Int(NSScreen.main?.frame.height ?? 1080)
        let r = ResolutionMath.resolution(mode: settings.settings.resolution,
                                          aspectRatio: settings.settings.aspectRatio,
                                          customWidth: customWidth, customHeight: customHeight,
                                          customScaler: customScaler,
                                          screenWidth: screenW, screenHeight: screenH,
                                          hasNotch: NSScreen.hasNotch())
        settings.settings.windowWidth = r.width
        settings.settings.windowHeight = r.height
        settings.settings.customScaler = customScaler
        showResolutionWarning = r.warn
    }

    func getWidthFromAspectRatio(_ height: Int) -> Int {
        ResolutionMath.widthFromAspectRatio(height: height, aspectRatio: settings.settings.aspectRatio)
    }

    func getHeightForNotch(_ width: Int, _ height: Int) -> Int {
        ResolutionMath.heightForNotch(width: width, height: height, hasNotch: NSScreen.hasNotch())
    }

    func setAspectRatioForResizableWindow() {
        let (w, h) = ResolutionMath.resizableRatio(type: settings.settings.resizableAspectRatioType,
                                                   customWidth: settings.settings.resizableAspectRatioWidth,
                                                   customHeight: settings.settings.resizableAspectRatioHeight)
        settings.settings.resizableAspectRatioWidth = w
        settings.settings.resizableAspectRatioHeight = h
    }
}
