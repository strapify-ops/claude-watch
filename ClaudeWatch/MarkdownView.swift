import SwiftUI

/// Small Markdown renderer for Claude's replies on a watch screen.
/// Block level: headings, paragraphs, bullet / numbered lists, quotes, code blocks, rules,
/// tables (one card per row, "Header: value" lines, which reads far better than a grid on a
/// 45 mm screen) and images (relay copies `cwimg:<sha1>` or http links; tap for full screen).
/// Inline styling (bold, italic, code, links) goes through AttributedString.
enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, Int)          // text, indent level
    case numbered(String, String)     // marker, text
    case quote(String)
    case code(String)
    case rule
    case table([String], [[String]])
    case image(String, String)        // alt, source
}

func parseMarkdown(_ text: String) -> [MDBlock] {
    var out: [MDBlock] = []
    var para: [String] = []
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var i = 0
    func flush() {
        if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
    }
    func cells(_ l: String) -> [String] {
        var t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    func isDivider(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|:- ".contains($0) }
    }
    let imageLine = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    while i < lines.count {
        let raw = lines[i]
        let t = raw.trimmingCharacters(in: .whitespaces)
        // fenced code
        if t.hasPrefix("```") {
            flush()
            var code: [String] = []
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i]); i += 1
            }
            out.append(.code(code.joined(separator: "\n")))
            i += 1; continue
        }
        // table: header row, divider row, body rows
        if t.hasPrefix("|") || (t.contains("|") && i + 1 < lines.count && isDivider(lines[i + 1])) {
            if i + 1 < lines.count, isDivider(lines[i + 1]) {
                flush()
                let head = cells(raw)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                out.append(.table(head, rows)); continue
            }
        }
        if t.isEmpty { flush(); i += 1; continue }
        if t == "---" || t == "***" || t == "___" { flush(); out.append(.rule); i += 1; continue }
        if t.hasPrefix("#") {
            let level = t.prefix(while: { $0 == "#" }).count
            if level <= 6, t.dropFirst(level).first == " " {
                flush(); out.append(.heading(level, String(t.dropFirst(level + 1)))); i += 1; continue
            }
        }
        if t.hasPrefix("> ") || t == ">" { flush(); out.append(.quote(String(t.dropFirst(min(2, t.count))))); i += 1; continue }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            flush()
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            out.append(.bullet(String(t.dropFirst(2)), min(indent, 3))); i += 1; continue
        }
        if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
           t[t.index(after: dot)...].first == " " {
            flush()
            out.append(.numbered(String(t[...dot]), String(t[t.index(dot, offsetBy: 2)...]))); i += 1; continue
        }
        // a line holding images: each image becomes its own block, text around it a paragraph
        let ns = t as NSString
        let matches = imageLine.matches(in: t, range: NSRange(location: 0, length: ns.length))
        if !matches.isEmpty {
            flush()
            var last = 0
            for m in matches {
                let before = ns.substring(with: NSRange(location: last, length: m.range.location - last)).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { out.append(.paragraph(before)) }
                out.append(.image(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
                last = m.range.location + m.range.length
            }
            let after = ns.substring(from: last).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty && after != "." { out.append(.paragraph(after)) }
            i += 1; continue
        }
        para.append(t); i += 1
    }
    flush()
    return out
}

struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseMarkdown(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
    }

    @ViewBuilder func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let l, let s):
            Text(md(s)).font(l <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 2)
        case .paragraph(let s):
            Text(md(s)).font(.footnote).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(indent == 0 ? "•" : "◦").font(.footnote)
                Text(md(s)).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, CGFloat(indent) * 8)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(n).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Text(md(s)).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            Text(md(s)).font(.footnote).italic().foregroundStyle(.secondary)
                .padding(.leading, 6).overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(size: 11, design: .monospaced)).padding(4)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        case .rule:
            Divider()
        case .table(let head, let rows):
            TableCards(head: head, rows: rows)
        case .image(let alt, let src):
            ReplyImage(alt: alt, src: src)
        }
    }
}

/// A Markdown table as cards: the first column is the card title, the rest "Header: value".
/// Tap the table for a sideways-scrolling grid of the original layout.
struct TableCards: View {
    let head: [String]; let rows: [[String]]
    var body: some View {
        NavigationLink { TableGrid(head: head, rows: rows) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(md(r.first ?? "")).font(.caption.weight(.semibold))
                        ForEach(1..<max(1, max(head.count, r.count)), id: \.self) { c in
                            let v = c < r.count ? r[c] : ""
                            if !v.isEmpty {
                                (Text(c < head.count ? head[c] + ": " : "").foregroundColor(.secondary) + Text(md(v)))
                                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct TableGrid: View {
    let head: [String]; let rows: [[String]]
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { ForEach(head.indices, id: \.self) { Text(md(head[$0])).font(.caption2.weight(.bold)) } }
                Divider()
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(head.indices, id: \.self) { c in
                            Text(md(c < rows[r].count ? rows[r][c] : "")).font(.caption2).frame(maxWidth: 140, alignment: .leading)
                        }
                    }
                }
            }.padding(4)
        }
    }
}

// MARK: - images

@MainActor final class ImageStore {
    static let shared = ImageStore()
    private var cache: [String: UIImage] = [:]
    func load(_ src: String, relay: String, token: String) async -> UIImage? {
        if let i = cache[src] { return i }
        var req: URLRequest
        if src.hasPrefix("cwimg:") {
            guard let u = URL(string: relay + "/api/img/" + src.dropFirst(6)) else { return nil }
            req = URLRequest(url: u)
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        } else if src.hasPrefix("https://") || src.hasPrefix("http://"), let u = URL(string: src) {
            req = URLRequest(url: u)
        } else { return nil }
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
        if cache.count > 30 { cache.removeAll() }
        cache[src] = img
        return img
    }
}

struct ReplyImage: View {
    @EnvironmentObject var m: Monitor
    let alt: String; let src: String
    @State private var img: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let img {
                NavigationLink { ZoomImage(img: img, title: alt) } label: {
                    Image(uiImage: img).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            } else if failed {
                Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: src) {
            img = await ImageStore.shared.load(src, relay: m.relay, token: m.token)
            failed = img == nil
        }
    }
}

/// Full screen: turn the Digital Crown to zoom (1x-5x), drag to pan, double-tap to reset.
struct ZoomImage: View {
    let img: UIImage; let title: String
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    var body: some View {
        GeometryReader { g in
            Image(uiImage: img).resizable().scaledToFit()
                .frame(width: g.size.width, height: g.size.height)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(DragGesture()
                    .onChanged { v in
                        offset = clamp(CGSize(width: dragStart.width + v.translation.width,
                                              height: dragStart.height + v.translation.height), g.size)
                    }
                    .onEnded { _ in dragStart = offset })
                .onTapGesture(count: 2) { withAnimation { zoom = 1; offset = .zero; dragStart = .zero } }
        }
        .clipped()
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 5, by: 0.1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, z in if z <= 1.01 { offset = .zero; dragStart = .zero } }
        .navigationTitle(title.isEmpty ? "Image" : title)
        .ignoresSafeArea(edges: .bottom)
    }
    /// keep the picture from being dragged off screen
    func clamp(_ s: CGSize, _ size: CGSize) -> CGSize {
        let mx = size.width * (zoom - 1) / 2, my = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(s.width, -mx), mx), height: min(max(s.height, -my), my))
    }
}
