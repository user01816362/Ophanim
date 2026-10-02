//
//  SwiftHooksEditor.swift
//  Ophanim
//
//  Visual editor for OPConfig.swiftHooks: index-keyed list plus the vtable-target
//  form (class runtime name + mangled-method substring, category, label).
//

import SwiftUI
import AppKit

/// Visual editor for OPConfig.swiftHooks. Rows are index-selected; selection is cleared before any
/// removal so no detail binding is left pointing at a stale index.
struct SwiftHooksEditorView: View {
    @Bindable var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPSwiftHook] { settings.settings.ophanim.swiftHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Swift Vtable Hooks").font(.headline)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let s = selection { remove(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.className.isEmpty ? "(class)" : h.className).font(.body)
                            Text("\(h.method.isEmpty ? "(method)" : h.method) · \(h.category.rawValue)")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(i)
                    }
                }
                .listStyle(.bordered).frame(width: 240)

                if let s = selection, s < hooks.count {
                    editor(s).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a hook").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            HStack {
                Text("\(hooks.count) hook(s) - overridable, non-@objc Swift methods dispatched through "
                     + "the vtable; observe-only (void). -O may devirtualize concrete calls. arm64 only. "
                     + "Use find_symbols to locate the class (_TtC… form) + mangled method. Applies on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .buttonStyle(.bordered)
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Target") {
                TextField("Class name (runtime _TtC… or Module.Class)", text: strBind(i, \.className))
                    .help("Swift class whose vtable to patch, by its runtime name (the _TtC… or "
                          + "Module.Class form find_symbols reports). Must be NSClassFromString-resolvable.")
                TextField("Method (substring of the mangled symbol)", text: strBind(i, \.method))
                    .help("Substring matched against each vtable slot's mangled symbol to pick the method "
                          + "(e.g. \"processPayload\"). Only overridable, vtable-dispatched methods are reachable.")
            }
            Section("Capture") {
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category to log under; must be enabled for the hook to fire.")
                TextField("Label (optional)", text: optStrBind(i, \.api))
                    .help("Event label for captured calls. Defaults to the matched mangled symbol.")
            }
        }
    }

    // MARK: - Helpers (index-keyed mutate/persist; selection cleared before removal)

    private func add() {
        var a = settings.settings.ophanim.swiftHooks
        a.append(OPSwiftHook(className: "", method: "", category: .process))
        settings.settings.ophanim.swiftHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.swiftHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.swiftHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPSwiftHook) -> Void) {
        var a = settings.settings.ophanim.swiftHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.swiftHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPSwiftHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPSwiftHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .process },
                set: { v in mutate(i) { $0.category = v } })
    }
}
