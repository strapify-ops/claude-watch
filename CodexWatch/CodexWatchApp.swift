import SwiftUI
import UserNotifications
import WatchKit

struct Session: Codable, Identifiable, Equatable {
    let id: String; let title: String; let cwd: String
    let state: String; let detail: String; let updated: Double
    var model: String? = nil; var effort: String? = nil
}
struct Tier: Codable, Hashable { let id: String; let name: String }
/// One entry of Codex's live model list, sent by the PC on every snapshot.
struct ModelInfo: Codable, Identifiable, Hashable {
    let slug: String; let name: String; let efforts: [String]; let defaultEffort: String; let tiers: [Tier]
    var id: String { slug }
}
struct CmdResult: Codable, Identifiable { let id: String; let session: String; let status: String; let message: String }
struct Snapshot: Codable {
    let version: Int; let pcOnline: Bool; let sessions: [Session]
    var catalog: [ModelInfo]? = nil; var results: [CmdResult]? = nil
    var quickReplies: [String]? = nil; var queued: [String]? = nil
}

@MainActor final class Monitor: ObservableObject {
    @AppStorage("relay") var relay = ""
    @AppStorage("token") var token = ""
    @Published var sessions: [Session] = []
    @Published var catalog: [ModelInfo] = []
    @Published var results: [CmdResult] = []
    @Published var quickReplies: [String] = []
    @Published var queued: [String] = []
    @Published var pcOnline = false
    @Published var error: String?
    private var version = -1
    private var known: [String: String] = [:]
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        task = Task { while !Task.isCancelled { await poll() } }
    }
    func stop() { task?.cancel(); task = nil }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard !relay.isEmpty, var c = URLComponents(string: relay + path) else { return nil }
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    private func poll() async {
        guard let req = request("/api/sessions", query: [URLQueryItem(name: "since", value: String(version))]) else {
            error = "Set relay in Settings"; try? await Task.sleep(for: .seconds(5)); return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            if snap.version != version { announce(snap.sessions, first: version < 0) }
            version = snap.version; sessions = snap.sessions; pcOnline = snap.pcOnline; error = nil
            catalog = snap.catalog ?? []; results = snap.results ?? []
            quickReplies = snap.quickReplies ?? []; queued = snap.queued ?? []
        } catch {
            self.error = "Relay unreachable"; try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Queue a prompt for a session. Empty model/effort/tier = keep the session's own.
    func send(session: String, prompt: String, model: String, effort: String, tier: String) async -> String? {
        guard var req = request("/api/commands") else { return "Set relay in Settings" }
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject:
            ["session": session, "prompt": prompt, "model": model, "effort": effort, "tier": tier])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 { WKInterfaceDevice.current().play(.click); return nil }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Send failed"
        } catch { return "Relay unreachable" }
    }

    /// Tap + notify when a session moves into ready or waiting.
    private func announce(_ new: [Session], first: Bool) {
        for s in new {
            let old = known[s.id]; known[s.id] = s.state
            guard !first, old != s.state, s.state == "ready" || s.state == "waiting" else { continue }
            WKInterfaceDevice.current().play(s.state == "waiting" ? .retry : .success)
            let n = UNMutableNotificationContent()
            n.title = s.state == "waiting" ? "Codex needs you" : "Codex is done"
            n.body = s.title + (s.detail.isEmpty ? "" : "\n" + s.detail)
            n.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + s.state, content: n, trigger: nil))
        }
    }
}

@main struct CodexWatchApp: App {
    @StateObject private var monitor = Monitor()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(monitor)
                .onChange(of: phase) { _, p in if p == .background { monitor.stop() } else { monitor.start() } }
                .onAppear { monitor.start() }
        }
    }
}
