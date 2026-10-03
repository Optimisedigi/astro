import CryptoKit
import Foundation

/// Only report data comes from the model. Layout, CSS and JavaScript are bundled
/// with the app, so search results cannot add executable markup to the page.
struct ResearchReport: Decodable {
    struct Fact: Decodable {
        let label: String
        let value: String
        let note: String?
    }
    struct Spec: Decodable {
        let label: String
        let value: String
    }
    struct Video: Decodable {
        let title: String
        let url: String
        let channel: String?
        let duration: String?
        let thumb: String?
        let note: String?
    }
    struct Item: Decodable {
        let name: String
        let price: String?
        let link: String?
        let specs: [Spec]
        let pros: [String]?
        let cons: [String]?
        let video: Video?
    }
    struct Comparison: Decodable {
        struct Row: Decodable {
            let feature: String
            let values: [String]
            let winner: Int?
        }
        let columns: [String]
        let rows: [Row]
        let video: Video?
    }
    struct Source: Decodable {
        let title: String
        let url: String
    }

    let title: String
    let kind: String?
    let date: String?
    let subtitle: String?
    let verdict: String
    let facts: [Fact]
    let items: [Item]
    let comparison: Comparison?
    let notes: [String]
    let sources: [Source]

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 300, !verdict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              facts.count == 4, facts.allSatisfy({ !$0.label.isEmpty && !$0.value.isEmpty && $0.value.count <= 20 }),
              (1...20).contains(items.count), (1...50).contains(sources.count), notes.count <= 50 else {
            throw ResearchReportError.invalid("Provide a title, verdict, four short key facts, 1–20 items, and 1–50 sources.")
        }
        for item in items {
            guard !item.name.isEmpty, (1...20).contains(item.specs.count),
                  (item.pros?.count ?? 0) <= 20, (item.cons?.count ?? 0) <= 20 else {
                throw ResearchReportError.invalid("Each item needs a name and 1–20 facts; pros and cons are optional.")
            }
            if let link = item.link { _ = try Self.webURL(link) }
            if let video = item.video { try validateVideo(video) }
        }
        for source in sources { _ = try Self.webURL(source.url) }
        if let comparison {
            guard (2...4).contains(comparison.columns.count), (1...100).contains(comparison.rows.count),
                  comparison.rows.allSatisfy({ row in
                      row.values.count == comparison.columns.count
                          && (row.winner == nil || comparison.columns.indices.contains(row.winner ?? -1))
                  }) else {
                throw ResearchReportError.invalid("Comparison tables need 2–4 columns and matching values; winners must be valid column indexes.")
            }
            if let video = comparison.video { try validateVideo(video) }
        }
    }

    private func validateVideo(_ video: Video) throws {
        _ = try Self.webURL(video.url)
        if let thumb = video.thumb {
            let url = try Self.webURL(thumb)
            guard url.scheme == "https", url.host == "i.ytimg.com", url.port == nil else {
                throw ResearchReportError.invalid("Video thumbnails must use https://i.ytimg.com; omit unverified thumbnails.")
            }
        }
    }

    static func webURL(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw ResearchReportError.invalid("Report links must be HTTP or HTTPS web addresses without embedded credentials.")
        }
        return url
    }
}

enum ResearchReportError: LocalizedError {
    case invalid(String)
    case missingTemplate(String)
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid research report: \(reason)"
        case .missingTemplate(let name): return "The app's research template is missing: \(name). Reinstall Astro."
        case .folderUnavailable(let path): return "Astro cannot use \(path). It must be a writable folder, not a shortcut or symbolic link."
        }
    }
}

enum ResearchReportRenderer {
    private static let themeScript = "document.querySelectorAll('.theme-toggle').forEach(b=>b.onclick=()=>{const r=document.documentElement;const dark=r.dataset.theme?r.dataset.theme==='dark':matchMedia('(prefers-color-scheme:dark)').matches;r.dataset.theme=dark?'light':'dark'});"

    static func render(_ report: ResearchReport, now: Date = Date()) throws -> String {
        try report.validate()
        let scriptHash = Data(SHA256.hash(data: Data(themeScript.utf8))).base64EncodedString()
        let policy = "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src https://i.ytimg.com; script-src 'sha256-\(scriptHash)'; base-uri 'none'; form-action 'none'"
        let date = report.date ?? now.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_AU")))
        let wide = report.items.count == 1 && report.comparison == nil
        let cards = report.items.map { renderItem($0, wide: wide) }.joined(separator: "\n")
        let values: [String: String] = [
            "TITLE": escape(report.title), "KIND": escape(report.kind ?? "Research brief"),
            "DATE": escape(date), "SUBTITLE": paragraph(report.subtitle, className: "subtitle"),
            "VERDICT": escape(report.verdict), "POLICY": escape(policy),
            "CSS": try template("review-sheet", extension: "css"), "SCRIPT": themeScript,
            "FACTS": report.facts.map { fact in
                "<div class=\"fact\"><span class=\"fact-label\">\(escape(fact.label))</span><span class=\"fact-value\">\(escape(fact.value))</span><span class=\"fact-note\">\(escape(fact.note ?? ""))</span></div>"
            }.joined(separator: "\n"),
            "ITEMS": wide ? cards : "<section class=\"items\">\(cards)</section>",
            "COMPARISON": report.comparison.map(renderComparison) ?? "",
            "NOTES": report.notes.map { "<li>\(escape($0))</li>" }.joined(),
            "SOURCES": report.sources.map { "<li>\(link($0.url, title: $0.title))</li>" }.joined(),
        ]
        // Replace only tokens in the original template. Text containing a token
        // must never be reinterpreted as another template substitution.
        let html = try template("review-sheet", extension: "html")
        let regex = try NSRegularExpression(pattern: #"\{\{([A-Z]+)\}\}"#)
        var result = ""
        var cursor = html.startIndex
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html), let keyRange = Range(match.range(at: 1), in: html),
                  let value = values[String(html[keyRange])] else {
                throw ResearchReportError.missingTemplate("unrecognized layout token")
            }
            result += html[cursor..<range.lowerBound] + value
            cursor = range.upperBound
        }
        return result + html[cursor...]
    }

    private static func template(_ name: String, extension ext: String) throws -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "ResearchTemplates") else {
            throw ResearchReportError.missingTemplate("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func paragraph(_ text: String?, className: String) -> String {
        guard let text, !text.isEmpty else { return "" }
        return "<p class=\"\(className)\">\(escape(text))</p>"
    }

    private static func link(_ url: String, title: String) -> String {
        "<a href=\"\(escape(url))\" target=\"_blank\" rel=\"noopener noreferrer\">\(escape(title))</a>"
    }

    private static func renderItem(_ item: ResearchReport.Item, wide: Bool) -> String {
        let specs = "<dl class=\"specs\">" + item.specs.map {
            "<div class=\"spec\"><dt>\(escape($0.label))</dt><dd>\(escape($0.value))</dd></div>"
        }.joined() + "</dl>"
        let lists = [("Pros", "good", "pro", item.pros ?? []), ("Cons", "bad", "con", item.cons ?? [])].compactMap { label, color, style, entries -> String? in
            guard !entries.isEmpty else { return nil }
            return "<ul class=\"proscons\" aria-label=\"\(label)\"><li><span class=\"proscons-label \(color)\">\(label)</span></li>" + entries.map { "<li class=\"\(style)\">\(escape($0))</li>" }.joined() + "</ul>"
        }.joined()
        let video = item.video.map(renderVideo) ?? ""
        let body: String
        if wide && (!video.isEmpty || !lists.isEmpty) {
            body = "<div class=\"card-body\">\(specs)<div class=\"side\">\(video)\(lists)</div></div>"
        } else {
            body = video + specs + lists
        }
        let productLink = item.link.map { link($0, title: "Source page ↗") } ?? ""
        return """
        <article class="card\(wide ? " wide" : "")">
          <div class="card-head"><div class="card-title"><h2>\(escape(item.name))</h2>\(productLink)</div>\(paragraph(item.price, className: "price"))</div>
          \(body)
        </article>
        """
    }

    private static func renderVideo(_ video: ResearchReport.Video) -> String {
        let image = video.thumb.map { "<img src=\"\(escape($0))\" alt=\"\" loading=\"lazy\">" } ?? ""
        let duration = video.duration.map { "<span class=\"duration\">\(escape($0))</span>" } ?? ""
        let meta = [video.channel, video.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return """
        <a class="video" href="\(escape(video.url))" target="_blank" rel="noopener noreferrer">
          <div class="thumb">\(image)<span class="play" aria-hidden="true">▶</span>\(duration)</div>
          <span class="video-title">\(escape(video.title)) ↗</span><span class="video-meta">\(escape(meta))</span>
        </a>
        """
    }

    private static func renderComparison(_ comparison: ResearchReport.Comparison) -> String {
        let headings = comparison.columns.map { "<th scope=\"col\">\(escape($0))</th>" }.joined()
        let rows = comparison.rows.map { row in
            let cells = row.values.enumerated().map { index, value in
                let winner = row.winner == index
                return "<td\(winner ? " class=\"win\"" : "")>\(winner ? "<span class=\"sr-only\">Stronger value: </span>" : "")\(escape(value))</td>"
            }.joined()
            return "<tr><th scope=\"row\">\(escape(row.feature))</th>\(cells)</tr>"
        }.joined()
        let video = comparison.video.map { link($0.url, title: $0.title) + paragraph($0.note, className: "fine") } ?? ""
        return """
        <section class="compare">
          <div class="compare-head"><h2>Head to head</h2>\(video)</div>
          <div class="table-scroll" tabindex="0" role="region" aria-label="Comparison table">
            <table><thead><tr><th scope="col">Feature</th>\(headings)</tr></thead><tbody>\(rows)</tbody></table>
          </div>
          <p class="fine">Highlighted cells mark objectively stronger values.</p>
        </section>
        """
    }
}
