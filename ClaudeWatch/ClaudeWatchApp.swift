import SwiftUI
import UserNotifications
import WatchKit

struct Session: Codable, Identifiable, Equatable {
    let id: String; let title: String; let cwd: String
    let state: String; let detail: String; let updated: Double
    var model: String? = nil; var effort: String? = nil
    var reply: String? = nil   // Claude's full last reply
}
struct Tier: Codable, Hashable { let id: String; let name: String }
/// One entry of Claude Code's live model list, sent by the PC on every snapshot.
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
    static let defaultRelay = "https://claude-watch.167-233-232-19.sslip.io"
    @AppStorage("relay") var relay = Monitor.defaultRelay
    @AppStorage("token") var token = ""
    var paired: Bool { !token.isEmpty }
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
    private var fresh = true
    private var failures = 0

    func start() {
        guard task == nil else { return }
        fresh = true; failures = 0
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

    /// Trade the 6-digit code shown on the PC for the relay token. Returns an error message or nil.
    func pair(code: String) async -> String? {
        guard var req = request("/api/pair/claim") else { return "Bad relay address" }
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (resp as? HTTPURLResponse)?.statusCode == 200, let t = obj?["token"] as? String {
                objectWillChange.send()   // @AppStorage inside an ObservableObject does not publish
                token = t; version = -1; error = nil
                WKInterfaceDevice.current().play(.success)
                return nil
            }
            WKInterfaceDevice.current().play(.failure)
            return obj?["error"] as? String ?? "Pairing failed"
        } catch { return "Relay unreachable" }
    }

    func unpair() { objectWillChange.send(); token = ""; sessions = []; version = -1 }

    private func poll() async {
        guard paired else { try? await Task.sleep(for: .seconds(2)); return }
        // First request after the app opens returns at once (no "since"), so a stale screen or
        // error never sits there for the 25 s a long poll can wait.
        let query = fresh ? [] : [URLQueryItem(name: "since", value: String(version))]
        guard let req = request("/api/sessions", query: query) else {
            error = "Set relay in Settings"; try? await Task.sleep(for: .seconds(5)); return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 401 { unpair(); return }   // token changed on the PC
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            if snap.version != version { announce(snap.sessions, first: version < 0) }
            version = snap.version; sessions = snap.sessions; pcOnline = snap.pcOnline; error = nil
            catalog = snap.catalog ?? []; results = snap.results ?? []
            quickReplies = snap.quickReplies ?? []; queued = snap.queued ?? []
            fresh = false; failures = 0
        } catch {
            // Leaving the app (wrist down) cancels the request: that is not a relay problem.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            failures += 1
            if failures >= 2 {   // one blip on watch Wi-Fi/LTE is normal; only say so when it persists
                self.error = error is DecodingError ? "Update the app (relay format changed)" : "Relay unreachable"
            }
            try? await Task.sleep(for: .seconds(failures >= 2 ? 5 : 1))
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
            n.title = s.state == "waiting" ? "Claude needs you" : "Claude is done"
            n.body = s.title + (s.detail.isEmpty ? "" : "\n" + s.detail)
            n.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + s.state, content: n, trigger: nil))
        }
    }
}

@main struct ClaudeWatchApp: App {
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
