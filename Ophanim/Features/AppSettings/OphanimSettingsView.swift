//
//  SettingsView.swift
//  Ophanim
//
//  Created by Andrew Glaze on 7/16/22.
//

import SwiftUI

struct OphanimSettingsView: View {
    private enum Tabs: Hashable {
        case keyCover, install, uninstall, mcp
    }

    var body: some View {
        TabView {
            // KeyCover tab hidden - KeyCover (at-rest encryption of the emulated keychain) is
            // intentionally disabled in Ophanim, so its settings tab is not surfaced.
            // Install tab removed - Galgal is always installed by default, and the per-app
            // "Application Type" now lives on each app's Application settings tab.
            UninstallSettings.shared
                .tabItem {
                  Label("preferences.tab.uninstall", systemImage: "trash.square")
                }
                .tag(Tabs.uninstall)
            MCPSettings()
                .tabItem {
                    Label("Automation", systemImage: "terminal")
                }
                .tag(Tabs.mcp)
        }
        
        .buttonStyle(.bordered)
    }
}

/// MCP (Model Context Protocol) automation preferences. Ophanim exposes a local MCP server so an
/// AI client can list apps, query captured events, read/change capture config, and launch apps.
/// Two transports: a loopback HTTP endpoint hosted by this app, and a headless `--mcp` stdio mode
/// an MCP client spawns directly.
struct MCPSettings: View {
    @AppStorage("ophanim.mcp.http") private var httpEnabled = true
    @AppStorage("ophanim.mcp.port") private var port = 20033
    @AppStorage("ophanim.mcp.bind") private var bindMode = "loopback"
    @AppStorage("ophanim.mcp.bindIP") private var bindIP = ""
    @State private var portText = ""

    private var binaryPath: String { Bundle.main.executablePath ?? "/Applications/Ophanim.app/Contents/MacOS/Ophanim" }
    private var stdioConfig: String {
        """
        {
          "mcpServers": {
            "ophanim": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("HTTP endpoint") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Serve MCP over HTTP (loopback only)", isOn: $httpEnabled)
                        .onChange(of: httpEnabled) { _, on in
                            if on { MCPHTTPTransport.shared.start() } else { MCPHTTPTransport.shared.stop() }
                        }
                    HStack {
                        Text("Port")
                        TextField("20033", text: $portText)
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                        Button("Apply") { applyPort() }
                        Text("(1024–65535, default 20033)").font(.caption).foregroundColor(.secondary)
                    }
                    .disabled(!httpEnabled)
                    HStack {
                        Text("Bind")
                        Picker("", selection: $bindMode) {
                            Text("Loopback (127.0.0.1)").tag("loopback")
                            Text("All interfaces (0.0.0.0)").tag("all")
                            Text("Specific IP").tag("specific")
                        }
                        .frame(width: 240)
                        .onChange(of: bindMode) { _, _ in restartIfRunning() }
                        Spacer()
                    }
                    .disabled(!httpEnabled)
                    if bindMode == "specific" {
                        HStack {
                            Text("IP address")
                            TextField("e.g. 192.168.1.50", text: $bindIP)
                                .frame(width: 200)
                                .onSubmit { restartIfRunning() }
                            Button("Apply") { restartIfRunning() }
                            Spacer()
                        }
                        .disabled(!httpEnabled)
                    }
                    if bindMode != "loopback" {
                        Text("⚠ This exposes the MCP server beyond this Mac. Anyone who can reach this "
                             + "address can read captured data and change capture settings. Use only on "
                             + "trusted networks.")
                            .font(.caption).foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("MCP clients connect at http://\(displayHost):\(String(port))/ - "
                         + "click Apply or re-toggle to rebind.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Headless (stdio)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For clients that spawn the server themselves (e.g. Claude Desktop), add this "
                         + "to the client's MCP config - no need to keep this app open:")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(stdioConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.tertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy config") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(stdioConfig, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Capabilities") {
                Text("Tools: list_apps · query_events · get_config · set_config · launch_app. "
                     + "The client can read captured behavior and change what each app captures.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { portText = String(port) }
    }

    /// Host shown in the connect-URL hint.
    private var displayHost: String {
        switch bindMode {
        case "all": return "0.0.0.0"
        case "specific": return bindIP.isEmpty ? "127.0.0.1" : bindIP
        default: return "127.0.0.1"
        }
    }

    /// Validate the typed port, persist it, and rebind the live server if it's running.
    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1024...65535).contains(value) else {
            portText = String(port)   // reject: revert the field
            return
        }
        port = value
        portText = String(value)
        restartIfRunning()
    }

    /// Rebind the live HTTP server to pick up a port/bind change.
    private func restartIfRunning() {
        guard httpEnabled else { return }
        MCPHTTPTransport.shared.stop()
        MCPHTTPTransport.shared.start()
    }
}
