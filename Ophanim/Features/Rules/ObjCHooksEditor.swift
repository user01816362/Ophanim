//
//  ObjCHooksEditor.swift
//  Ophanim
//

import SwiftUI
import AppKit

/// Visual editor for OPConfig.objcHooks. Rows are index-selected; selection is cleared before any
/// removal so no detail binding is left pointing at a stale index.
struct ObjCHooksEditorView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPObjCHook] { settings.settings.ophanim.objcHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ObjC Boundary Hooks").font(.headline)
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
                            Text("\(h.classMethod ? "+" : "-")\(h.selector.isEmpty ? "(selector)" : h.selector) · \(h.category.rawValue)")
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
                Text("\(hooks.count) hook(s) - @objc methods only (objc_msgSend-dispatched); void methods; "
                     + "captured args incl. NSData. Applies on next app launch.")
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

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Target") {
                TextField("Class name (e.g. NSURLSession)", text: strBind(i, \.className))
                    .help("Objective-C class to swizzle, by its runtime name (as NSClassFromString sees it).")
                TextField("Selector (e.g. URLSession:dataTask:didReceiveData:)", text: strBind(i, \.selector))
                    .help("Method selector to hook. Only void methods are hooked (the data-callback shape); "
                          + "value-returning selectors are skipped.")
                Toggle("Class method (+)", isOn: boolBind(i, \.classMethod))
                    .help("On = hook the class (+) method; off = the instance (-) method.")
                Picker("Object args", selection: argsBind(i)) {
                    ForEach(0...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many leading object arguments to log (NSData is captured as a body, NSString as "
                      + "a field).")
            }
            Section("Capture") {
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category to log under; must be enabled for the hook to fire.")
                TextField("Label (optional)", text: optStrBind(i, \.api))
                    .help("Event label + rule-matching name. Defaults to \"Class.selector\".")
            }
        }
    }

    // MARK: index-safe mutate/persist helpers (selection cleared before removal)

    private func add() {
        var a = settings.settings.ophanim.objcHooks
        a.append(OPObjCHook(className: "", selector: "", args: 1, classMethod: false, category: .network))
        settings.settings.ophanim.objcHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.objcHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.objcHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPObjCHook) -> Void) {
        var a = settings.settings.ophanim.objcHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.objcHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func boolBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, Bool>) -> Binding<Bool> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : false },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func argsBind(_ i: Int) -> Binding<Int> {
        Binding(get: { i < hooks.count ? hooks[i].args : 1 },
                set: { v in mutate(i) { $0.args = v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .network },
                set: { v in mutate(i) { $0.category = v } })
    }
}
