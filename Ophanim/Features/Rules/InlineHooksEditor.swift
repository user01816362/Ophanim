//
//  InlineHooksEditor.swift
//  Ophanim
//

import SwiftUI
import AppKit

/// Visual editor for OPConfig.inlineHooks. Index-keyed; selection cleared before removal.
struct InlineHooksEditorView: View {
    @Bindable var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPInlineHook] { settings.settings.ophanim.inlineHooks }
    private var armed: Bool { settings.settings.ophanim.enableInlineHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Inline Hooks").font(.headline)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let s = selection { remove(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            if !armed {
                Text("⚠ Inline hooks are OFF - turn on “Enable inline hooks” in Hacking to arm these.")
                    .font(.caption).foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.api.isEmpty ? "(label)" : h.api).font(.body)
                            Text("\(targetSummary(h)) · \(h.category.rawValue)")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(i)
                    }
                }
                .listStyle(.bordered).frame(width: 250)

                if let s = selection, s < hooks.count {
                    editor(s).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a hook").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            HStack {
                Text("\(hooks.count) hook(s) - located by address / symbol / module+offset / signature "
                     + "(from Ghidra or by hand). arm64; applies on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
    }

    private func targetSummary(_ h: OPInlineHook) -> String {
        if let a = h.address, !a.isEmpty { return a }
        if let s = h.symbol, !s.isEmpty { return s }
        if let o = h.offset, !o.isEmpty { return "\(h.module ?? "exe")+\(o)" }
        if let g = h.signature, !g.isEmpty { return "sig \(g.prefix(16))…" }
        return "(unresolved)"
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Identity") {
                TextField("Label (api)", text: strBind(i, \.api))
                    .help("Display name for captured events from this hook, and what an interception "
                          + "rule's API glob matches against (e.g. \"grpc_unary_req\").")
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category this hook logs under. The category must be enabled for the hook "
                      + "to install and fire.")
            }
            Section("Target - first non-empty field wins") {
                TextField("Absolute address (0x…)", text: optStrBind(i, \.address))
                    .help("Exact runtime address to patch (hex). Rarely used - addresses move with ASLR; "
                          + "prefer module+offset or a signature.")
                TextField("Symbol (dlsym)", text: optStrBind(i, \.symbol))
                    .help("Exported symbol name resolved via dlsym (e.g. a C function or @_cdecl export). "
                          + "Enable “Follow leading branch” if it resolves to a one-instruction thunk.")
                TextField("Module (path substring; blank = main executable)", text: optStrBind(i, \.module))
                    .help("Substring of the loaded image's path that scopes the offset/signature lookup "
                          + "(e.g. \"Snapchat\" or a framework name). Blank = the app's main executable.")
                TextField("Offset in module (0x… or decimal)", text: optStrBind(i, \.offset))
                    .help("Static offset within the module as Ghidra reports it (relative to the image's "
                          + "preferred base). The ASLR slide is added automatically at runtime.")
                TextField("Signature (e.g. 1F 20 ?? D5)", text: optStrBind(i, \.signature))
                    .help("Byte pattern scanned over the module's executable text; “??” matches any byte. "
                          + "Survives recompiles better than a fixed offset.")
                Toggle("Follow leading branch (thunk)", isOn: boolBind(i, \.followThunk))
                    .help("If the resolved address is a one-instruction unconditional branch (common for "
                          + "exported Swift), hook the real function it jumps to instead of the thunk.")
            }
            Section("Render - deref a register as an object") {
                ForEach(0..<8, id: \.self) { r in
                    Picker("x\(r)", selection: renderArgBind(i, r)) { renderOptions() }
                        .help("How to capture argument register x\(r): “(none)” logs the raw pointer; nsdata "
                              + "captures the bytes as a body; nsstring/objcDesc/cString decode it. "
                              + "Safe - a non-object value falls back to hex.")
                }
                Picker("return", selection: renderReturnBind(i)) { renderOptions() }
                    .help("Render the return value the same way. This runs the original first (enter/leave) "
                          + "to observe the real result, so it implies “capture return”.")
            }
        }
    }

    @ViewBuilder private func renderOptions() -> some View {
        Text("(none)").tag(OPArgRender?.none)
        ForEach(OPArgRender.allCases, id: \.self) { Text($0.rawValue).tag(OPArgRender?.some($0)) }
    }

    // MARK: index-safe mutate/persist helpers

    private func add() {
        var a = settings.settings.ophanim.inlineHooks
        a.append(OPInlineHook(api: "", category: .process))
        settings.settings.ophanim.inlineHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.inlineHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.inlineHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPInlineHook) -> Void) {
        var a = settings.settings.ophanim.inlineHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.inlineHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func boolBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, Bool>) -> Binding<Bool> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : false },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .process },
                set: { v in mutate(i) { $0.category = v } })
    }
    private func renderArgBind(_ i: Int, _ r: Int) -> Binding<OPArgRender?> {
        Binding(get: { i < hooks.count ? hooks[i].renderArgs?["x\(r)"] : nil },
                set: { v in mutate(i) { h in
                    var m = h.renderArgs ?? [:]
                    if let v = v { m["x\(r)"] = v } else { m.removeValue(forKey: "x\(r)") }
                    h.renderArgs = m.isEmpty ? nil : m
                } })
    }
    private func renderReturnBind(_ i: Int) -> Binding<OPArgRender?> {
        Binding(get: { i < hooks.count ? hooks[i].renderReturn : nil },
                set: { v in mutate(i) { $0.renderReturn = v } })
    }
}
