import SwiftUI
import WidgetKit

/// Watch-face complication: how many Claude sessions need you, are working, are done.
/// It reads the relay itself (one quick request), so it stays current with the app closed.
/// The app also asks for a reload whenever the counts change while it is open.
struct SessionsEntry: TimelineEntry {
    let date: Date
    let counts: SessionCounts
    let online: Bool       // relay reached and the PC is feeding it
    let paired: Bool
}

struct SessionsProvider: TimelineProvider {
    static let sample = SessionsEntry(date: Date(), counts: SessionCounts(waiting: 1, working: 2, ready: 5, topWaiting: "Google Ads review"), online: true, paired: true)

    func placeholder(in context: Context) -> SessionsEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        if context.isPreview { return completion(Self.sample) }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        Task {
            let e = await load()
            // watchOS allows a few dozen background reloads a day; every 15 min fits, and
            // sooner while something is running or needs you.
            let mins = (e.counts.working > 0 || e.counts.waiting > 0) ? 10.0 : 15.0
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(mins * 60))))
        }
    }

    private func load() async -> SessionsEntry {
        guard !SharedConfig.token.isEmpty else {
            return SessionsEntry(date: Date(), counts: SessionCounts([]), online: false, paired: false)
        }
        if let (c, pc) = await SharedConfig.fetchCounts() {
            return SessionsEntry(date: Date(), counts: c, online: pc, paired: true)
        }
        return SessionsEntry(date: Date(), counts: SessionCounts([]), online: false, paired: true)
    }
}

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SessionsEntry
    var c: SessionCounts { entry.counts }

    /// the one number that matters most: waiting, else working, else done
    var main: (Int, String, Color) {
        if c.waiting > 0 { return (c.waiting, "hand.raised.fill", .orange) }
        if c.working > 0 { return (c.working, "gearshape.2.fill", .blue) }
        return (c.ready, "checkmark.circle.fill", .green)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if !entry.paired { Text("Claude: pair in app") }
            else if !entry.online { Text("Claude: PC offline") }
            else { Text(inline) }
        case .accessoryCorner:
            Image(systemName: main.1).font(.title3).foregroundStyle(main.2)
                .widgetLabel { Text(entry.online ? "\(main.0) \(c.waiting > 0 ? "waiting" : c.working > 0 ? "working" : "ready")" : "offline") }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle").foregroundStyle(.orange)
                    Text("Claude").font(.headline)
                    if !entry.online { Text(entry.paired ? "offline" : "pair").font(.caption2).foregroundStyle(.secondary) }
                }
                if let t = c.topWaiting {
                    Text(t).font(.caption2).lineLimit(1).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Label("\(c.waiting)", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    Label("\(c.working)", systemImage: "gearshape.2.fill").foregroundStyle(.blue)
                    Label("\(c.ready)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.caption2.monospacedDigit())
            }
        default: // accessoryCircular
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: main.1).font(.caption).foregroundStyle(main.2)
                    Text(entry.online ? "\(main.0)" : "–").font(.system(.title3, design: .rounded).weight(.bold))
                }
            }
        }
    }

    var inline: String {
        if c.waiting > 0 { return "Claude: \(c.waiting) waiting · \(c.working) working" }
        if c.working > 0 { return "Claude: \(c.working) working" }
        return "Claude: \(c.ready) ready"
    }
}

@main
struct ClaudeWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeSessions", provider: SessionsProvider()) { entry in
            SessionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)   // tapping it opens the app
        }
        .configurationDisplayName("Claude sessions")
        .description("Sessions waiting for you, working and ready.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
