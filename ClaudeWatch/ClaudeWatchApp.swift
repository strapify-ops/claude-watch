import SwiftUI
import UserNotifications
import WatchKit
import WidgetKit

@MainActor final class Monitor: ObservableObject {
    static let defaultRelay = SharedConfig.defaultRelay
    // Kept in a keychain item shared with the complication (see Shared/Shared.swift).
    var relay: String {
        get { SharedConfig.relay }
        set { objectWillChange.send(); SharedConfig.relay = newValue }
    }
    var token: String {
        get { SharedConfig.token }
        set { objectWillChange.send(); SharedConfig.token = newValue; WidgetCenter.shared.reloadAllTimelines() }
    }
    var paired: Bool { !token.isEmpty }
    @Published var sessions: [Session] = []
    @Published var catalog: [ModelInfo] = []
    @Published var results: [CmdResult] = []
    @Published var quickReplies: [String] = []
    @Published var queued: [String] = []
    /// nil until the relay has answered once since the app opened: unknown, never "offline"
    @Published var pcOnline: Bool? = nil
    @Published var error: String?
    private var version = -1
    private var known: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var lastCounts: SessionCounts?
    var pushRegistered = false

    /// Give the relay this watch's APNs token so it can notify with the app closed.
    func registerPush(_ deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard var req = request("/api/push/register") else { return }
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": hex])
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            pushRegistered = (o?["push"] as? Bool) == true   // relay has an APNs key: it will notify
        }
    }
    private var fresh = true
    private var failures = 0

    func start() {
        guard task == nil else { return }
        fresh = true; failures = 0
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { DispatchQueue.main.async { WKApplication.shared().registerForRemoteNotifications() } }
        }
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
            if snap.version != version {
                announce(snap.sessions, first: version < 0)
                // complication: refresh when the counts it shows change (reloads are budgeted)
                let counts = SessionCounts(snap.sessions)
                if counts != lastCounts { lastCounts = counts; WidgetCenter.shared.reloadAllTimelines() }
            }
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
            // With push working the relay sends the notification; a local one would double it.
            if pushRegistered { continue }
            let n = UNMutableNotificationContent()
            n.title = s.state == "waiting" ? "Claude needs you" : "Claude is done"
            n.body = s.title + (s.detail.isEmpty ? "" : "\n" + s.detail)
            n.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id + s.state, content: n, trigger: nil))
        }
    }
}

/// Receives the APNs device token and hands it to the monitor.
final class AppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var monitor: Monitor?
    var pendingToken: Data?
    func applicationDidFinishLaunching() { UNUserNotificationCenter.current().delegate = self }
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Task { @MainActor in
            if let m = monitor, m.paired { await m.registerPush(deviceToken) } else { pendingToken = deviceToken }
        }
    }
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) { print("push registration failed:", error) }
    // App open: the list already updates and taps the wrist, so no banner on top of it.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [] }
}

@main struct ClaudeWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var monitor = Monitor()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(monitor)
                .task {
                    delegate.monitor = monitor
                    // token arrived before the app was paired / ready
                    if let t = delegate.pendingToken, monitor.paired { await monitor.registerPush(t); delegate.pendingToken = nil }
                }
                .onChange(of: monitor.paired) { _, p in
                    if p { WKApplication.shared().registerForRemoteNotifications() }   // re-send the token after pairing
                }
                .onChange(of: phase) { _, p in if p == .background { monitor.stop() } else { monitor.start() } }
                .onAppear { monitor.start() }
        }
    }
}
