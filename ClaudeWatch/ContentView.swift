import SwiftUI

struct ContentView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        NavigationStack {
            if !m.paired { PairView().navigationTitle("Claude") } else {
            List {
                if let e = m.error { Text(e).foregroundStyle(.red).font(.footnote) }
                else if !m.pcOnline { Label("PC offline", systemImage: "desktopcomputer").foregroundStyle(.orange) }
                if m.sessions.isEmpty && m.error == nil { Text("No recent Claude sessions").foregroundStyle(.secondary) }
                ForEach(m.sessions) { s in
                    NavigationLink { DetailView(s: s) } label: { Row(s: s) }
                }
                NavigationLink("Settings") { SettingsView() }
            }
            .navigationTitle("Claude")
            }
        }
    }
}

/// First run (or after the token changes): type the 6-digit code from "Pair Claude Watch" on the PC.
struct PairView: View {
    @EnvironmentObject var m: Monitor
    @State private var code = ""
    @State private var status: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("On your PC, open \"Pair Claude Watch\" and type the code.").font(.footnote).multilineTextAlignment(.center)
                TextField("6-digit code", text: $code)
                    .multilineTextAlignment(.center)
                    .onChange(of: code) { _, v in
                        let d = String(v.filter(\.isNumber).prefix(6))
                        if d != v { code = d }
                    }
                Button(busy ? "Pairing..." : "Pair") {
                    busy = true
                    Task { status = await m.pair(code: code); busy = false; if status != nil { code = "" } }
                }
                .disabled(code.count != 6 || busy)
                if let status { Text(status).foregroundStyle(.red).font(.footnote) }
                NavigationLink("Relay address") { SettingsView() }.font(.footnote)
            }
        }
    }
}

struct Row: View {
    let s: Session
    var full = false   // detail page: whole title; list: two lines
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(s.title).font(.headline).lineLimit(full ? nil : 2)
                Text(label).font(.caption2).foregroundStyle(color)
            }
        }
    }
    var icon: String { ["waiting": "hand.raised.fill", "ready": "checkmark.circle.fill", "working": "gearshape.2.fill"][s.state] ?? "stop.circle" }
    var color: Color { ["waiting": .orange, "ready": .green, "working": .blue][s.state] ?? .gray }
    var label: String { ["waiting": "Waiting for you", "ready": "Ready", "working": "Working..."][s.state] ?? "Stopped" }
}

/// Claude's replies are Markdown: render bold/italic/code/links, keep line breaks and lists as text.
func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct DetailView: View {
    @EnvironmentObject var m: Monitor
    let s: Session
    /// Re-read from the monitor so state/model refresh while the page is open.
    var live: Session { m.sessions.first { $0.id == s.id } ?? s }
    var body: some View {
        List {
            Row(s: live, full: true)
            if let reply = live.reply, !reply.isEmpty {
                Text(md(reply)).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } else if !live.detail.isEmpty {
                Text(live.detail).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if let model = live.model, !model.isEmpty {
                Text("\(m.catalog.first { $0.slug == model }?.name ?? model) · \(live.effort ?? "")").font(.caption2)
            }
            Text(Date(timeIntervalSince1970: live.updated), style: .relative).font(.caption2).foregroundStyle(.secondary)
            NavigationLink { ComposeView(s: live) } label: { Label("Send to Claude", systemImage: "paperplane.fill") }
                .disabled(live.state == "working" || !m.pcOnline)
            ForEach(m.results.filter { $0.session == s.id }) { r in
                VStack(alignment: .leading) {
                    Text(r.status.capitalized).font(.caption2).foregroundStyle(r.status == "failed" ? .red : .secondary)
                    Text(md(r.message)).font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Prompt + model + effort + speed, all drawn from the PC live Claude Code catalog.
struct ComposeView: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.dismiss) private var dismiss
    let s: Session
    @State private var prompt = ""
    @State private var model = ""      // "" = keep session's model
    @State private var effort = ""     // "" = keep session's effort
    @State private var tier = ""
    @State private var status: String?
    @State private var sending = false

    var chosen: ModelInfo? { m.catalog.first { $0.slug == (model.isEmpty ? (s.model ?? "") : model) } }

    var body: some View {
        Form {
            Section {
                TextField("Message", text: $prompt, axis: .vertical)
                ForEach(m.quickReplies, id: \.self) { q in Button(q) { prompt = q } }
            }
            Section("Model") {
                Picker("Model", selection: $model) {
                    Text("Keep (\(m.catalog.first { $0.slug == s.model }?.name ?? s.model ?? "default"))").tag("")
                    ForEach(m.catalog) { Text($0.name).tag($0.slug) }
                }
                Picker("Effort", selection: $effort) {
                    Text("Keep (\(s.effort ?? "default"))").tag("")
                    ForEach(chosen?.efforts ?? [], id: \.self) { e in
                        Text(e == chosen?.defaultEffort ? "\(e) (default)" : e).tag(e)
                    }
                }
                if let tiers = chosen?.tiers, !tiers.isEmpty {
                    Picker("Speed", selection: $tier) {
                        Text("Standard").tag("")
                        ForEach(tiers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .onChange(of: model) { _, _ in
                // efforts/tiers differ per model: drop choices the new model doesn't support
                if !effort.isEmpty, !(chosen?.efforts.contains(effort) ?? false) { effort = "" }
                if !tier.isEmpty, !(chosen?.tiers.contains { $0.id == tier } ?? false) { tier = "" }
            }
            Button(sending ? "Sending..." : "Send") {
                sending = true
                Task {
                    status = await m.send(session: s.id, prompt: prompt, model: model, effort: effort, tier: tier)
                    sending = false
                    if status == nil { dismiss() }
                }
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            if let status { Text(status).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Send")
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("relay") var relay = Monitor.defaultRelay
    var body: some View {
        Form {
            TextField("Relay URL", text: $relay).textContentType(.URL)
            if relay != Monitor.defaultRelay { Button("Use default relay") { relay = Monitor.defaultRelay } }
            if m.paired { Button("Unpair", role: .destructive) { m.unpair() } }
        }
    }
}
