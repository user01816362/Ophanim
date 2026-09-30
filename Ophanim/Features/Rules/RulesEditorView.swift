//
//  RulesEditorView.swift
//  Ophanim
//
//  Visual editor for the per-app interception rules (settings.settings.ophanim.rules). Each rule
//  is a matcher (category / host / url / path / api globs) + an action (observe / block / delay /
//  fault / modify-args / replace-return / script). Edits persist via the AppSettings didSet.
//
//  Identity: rows are selected and bound by the rule's `id` string, NOT by array index. Binding
//  into `rules[index]` by a captured index crashes (Array index out of range) the moment a rule is
//  removed - SwiftUI pushes one more update into the detail editor's bindings with a now-stale
//  index. Looking the rule up by id at get/set time degrades to a safe no-op instead.
//

import SwiftUI
import AppKit

struct RulesEditorView: View {
    @Bindable var settings: AppSettings
    @State private var selection: String?

    private var rules: [OPRule] { settings.settings.ophanim.rules }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Interception Rules").font(.headline)
                Spacer()
                Button { addRule() } label: { Image(systemName: "plus") }
                Button { if let s = selection { removeRule(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }

            HStack(alignment: .top, spacing: 12) {
                // Rule list
                List(selection: $selection) {
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.id).font(.body)
                            Text("\(rule.action.kind.rawValue)\(rule.enabled ? "" : " (off)")")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(rule.id)
                    }
                }
                .listStyle(.bordered).frame(width: 210)

                // Detail editor - keyed by id; vanishes cleanly if the selected rule is gone.
                if let sel = selection, rules.contains(where: { $0.id == sel }) {
                    ruleEditor(sel).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a rule").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            HStack {
                Text("\(rules.count) rule(s) - observe-by-default; rules apply on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
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

    @ViewBuilder private func ruleEditor(_ id: String) -> some View {
        Form {
            Section("Rule") {
                TextField("ID", text: idBind(id))
                Toggle("Enabled", isOn: boolBind(\.enabled, id))
                TextField("Note", text: optStrBind(\.note, id))
            }
            Section("Match (all set fields must match)") {
                Picker("Category", selection: catBind(id)) {
                    Text("Any").tag(OPCategory?.none)
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag(OPCategory?.some($0)) }
                }
                TextField("API glob (e.g. SecItem*)", text: matchBind(\.apiGlob, id))
                TextField("Host glob (e.g. *.analytics.com)", text: matchBind(\.hostGlob, id))
                TextField("URL glob", text: matchBind(\.urlGlob, id))
                TextField("Path glob", text: matchBind(\.pathGlob, id))
            }
            Section("Action") {
                Picker("Do", selection: actionKindBind(id)) {
                    ForEach(OPAction.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                switch rule(id)?.action.kind {
                case .replaceReturn:
                    TextField("Canned return value", text: actStrBind(\.cannedReturnValue, id))
                    TextField("HTTP status", text: actIntBind(\.replacementStatus, id))
                case .delay:
                    TextField("Delay (ms)", text: actIntBind(\.delayMilliseconds, id))
                case .fault:
                    TextField("Error code", text: actIntBind(\.faultErrorCode, id))
                case .script:
                    Text("JavaScript (mutate ctx: set ctx.block, ctx.replacementBody (base64), ctx.replacementStatus, ctx.returnValue)")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: actStrBind(\.script, id)).frame(height: 90).font(.system(.body, design: .monospaced))
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: mutate-and-persist helpers (all keyed by rule id, never by array index)

    private func rule(_ id: String) -> OPRule? { rules.first(where: { $0.id == id }) }

    private func addRule() {
        var r = settings.settings.ophanim.rules
        // Generate an id that doesn't collide with an existing rule (ids are the identity here).
        var n = r.count + 1
        var newID = "rule-\(n)"
        while r.contains(where: { $0.id == newID }) { n += 1; newID = "rule-\(n)" }
        r.append(OPRule(id: newID, match: OPMatcher(), action: OPAction(kind: .observe)))
        settings.settings.ophanim.rules = r
        selection = newID
    }

    private func removeRule(_ id: String) {
        var r = settings.settings.ophanim.rules
        guard let i = r.firstIndex(where: { $0.id == id }) else { return }
        // Clear selection BEFORE mutating so no detail binding is left pointing at the removed rule.
        selection = nil
        r.remove(at: i)
        settings.settings.ophanim.rules = r
    }

    /// Mutate the rule with `id` in place and persist. No-ops if the rule no longer exists.
    private func mutate(_ id: String, _ body: (inout OPRule) -> Void) {
        var r = settings.settings.ophanim.rules
        guard let i = r.firstIndex(where: { $0.id == id }) else { return }
        body(&r[i])
        settings.settings.ophanim.rules = r
    }

    /// The ID field is special: editing it changes the rule's identity, so keep `selection` in sync.
    private func idBind(_ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.id ?? id },
                set: { newID in
                    let trimmed = newID
                    mutate(id) { $0.id = trimmed }
                    if selection == id { selection = trimmed }
                })
    }
    private func boolBind(_ kp: WritableKeyPath<OPRule, Bool>, _ id: String) -> Binding<Bool> {
        Binding(get: { rule(id)?[keyPath: kp] ?? false },
                set: { v in mutate(id) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ kp: WritableKeyPath<OPRule, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func matchBind(_ kp: WritableKeyPath<OPMatcher, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.match[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0.match[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func catBind(_ id: String) -> Binding<OPCategory?> {
        Binding(get: { rule(id)?.match.categories?.first },
                set: { v in mutate(id) { $0.match.categories = v.map { [$0] } } })
    }
    private func actionKindBind(_ id: String) -> Binding<OPAction.Kind> {
        Binding(get: { rule(id)?.action.kind ?? .observe },
                set: { v in mutate(id) { $0.action.kind = v } })
    }
    private func actStrBind(_ kp: WritableKeyPath<OPAction, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.action[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0.action[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func actIntBind(_ kp: WritableKeyPath<OPAction, Int?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.action[keyPath: kp].map(String.init) ?? "" },
                set: { v in mutate(id) { $0.action[keyPath: kp] = Int(v) } })
    }
}
