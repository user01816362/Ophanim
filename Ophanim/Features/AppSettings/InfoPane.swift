//
//  InfoPane.swift
//  Ophanim
//
//  Read-only app identity pane: bundle names/ids, versions, category, executable,
//  minimum OS, Galgal presence, and install paths.
//

import SwiftUI

/// Read-only identity sheet for one hosted app (Info.plist facts + install state).
struct InfoView: View {
    @State var info: AppInfo
    @State var hasGalgal: Bool

    var body: some View {
        List {
            HStack {
                Text("settings.info.displayName")
                Spacer()
                Text("\(info.displayName)")
            }
            HStack {
                Text("settings.info.bundleName")
                Spacer()
                Text("\(info.bundleName)")
            }
            HStack {
                Text("settings.info.bundleIdentifier")
                Spacer()
                Text("\(info.bundleIdentifier)")
            }
            HStack {
                Text("settings.info.bundleVersion")
                Spacer()
                Text("\(info.bundleVersion)")
            }
            HStack {
                Text("settings.applicationCategoryType") + Text(":")
                Spacer()
                Text("\(info.applicationCategoryType.rawValue)")
            }
            HStack {
                Text("settings.info.executableName")
                Spacer()
                Text("\(info.executableName)")
            }
            HStack {
                Text("settings.info.minimumOSVersion")
                Spacer()
                Text("\(info.minimumOSVersion)")
            }
            HStack {
                Text("settings.info.galgal")
                Spacer()
                Text(hasGalgal ? "button.Yes" : "button.No")
            }
            HStack {
                Text("settings.info.url")
                Spacer()
                Text("\(info.url.relativePath)")
            }
            HStack {
                Text("settings.info.alias")
                Spacer()
                Text("\(HostedApp.aliasDirectory.appendingPathComponent(info.bundleIdentifier))")
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .padding()
    }
}
