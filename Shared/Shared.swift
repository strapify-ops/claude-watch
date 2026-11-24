import Foundation
import Security

// Shared by the watch app and the complication (widget extension).

struct Session: Codable, Identifiable, Equatable {
    let id: String; let title: String; let cwd: String
    let state: String; let detail: String; let updated: Double
    var model: String? = nil; var effort: String? = nil
    var reply: String? = nil   // Claude's full last reply
    var summary: String? = nil // wrap-up recap + outstanding list: what Read aloud says
}
struct Tier: Codable, Hashable { let id: String; let name: String }
/// One entry of Claude Code's live model list, sent by the PC on every snapshot.
struct ModelInfo: Codable, Identifiable, Hashable {
    let slug: String; let name: String; let efforts: [String]; let defaultEffort: String; let tiers: [Tier]
    var effortNames: [String: String]? = nil   // "xhigh" -> "Extra", as the desktop app labels them
    var id: String { slug }
}
struct CmdResult: Codable, Identifiable { let id: String; let session: String; let status: String; let message: String }
struct Snapshot: Codable {
    let version: Int; let pcOnline: Bool; let sessions: [Session]
    var catalog: [ModelInfo]? = nil; var results: [CmdResult]? = nil
    var quickReplies: [String]? = nil; var queued: [String]? = nil
}

/// What the complication shows.
struct SessionCounts: Equatable, Codable {
    var waiting = 0, working = 0, ready = 0
    var topWaiting: String? = nil      // title of the newest session that needs you
    init(_ sessions: [Session]) {
        for s in sessions {
            switch s.state {
            case "waiting": waiting += 1; if topWaiting == nil { topWaiting = s.title }
            case "working": working += 1
            case "ready": ready += 1
            default: break
            }
        }
    }
    init(waiting: Int, working: Int, ready: Int, topWaiting: String?) {
        self.waiting = waiting; self.working = working; self.ready = ready; self.topWaiting = topWaiting
    }
}

/// Relay address + token, in a keychain item both the app and the complication can read
/// (keychain sharing needs no app group: every profile of the team allows TEAMID.*).
enum SharedConfig {
    static let defaultRelay = "https://claude-watch.167-233-232-19.sslip.io"
    static let accessGroup = "6JGS69NZ47.au.com.strapify.claudewatch.shared"
    private static let service = "au.com.strapify.claudewatch"

    static var token: String {
        get { read("token") ?? migrate("token") ?? "" }
        set { write("token", newValue) }
    }
    static var relay: String {
        get { read("relay") ?? migrate("relay") ?? defaultRelay }
        set { write("relay", newValue) }
    }

    /// Builds 1-6 kept these in the app's UserDefaults; move them over once.
    private static func migrate(_ key: String) -> String? {
        guard let v = UserDefaults.standard.string(forKey: key), !v.isEmpty else { return nil }
        write(key, v)
        if read(key) == v { UserDefaults.standard.removeObject(forKey: key) }
        return v
    }

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrAccessGroup as String: accessGroup]
    }
    private static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func write(_ key: String, _ value: String) {
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        // readable while the watch is locked on the wrist, so the complication can refresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// One immediate (non-waiting) read of the relay, for the complication.
    static func fetchCounts() async -> (SessionCounts, Bool)? {
        guard !token.isEmpty, let url = URL(string: relay + "/api/sessions") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return (SessionCounts(snap.sessions), snap.pcOnline)
    }
}
