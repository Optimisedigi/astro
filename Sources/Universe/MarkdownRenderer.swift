import SwiftUI

/// Hand-written markdown scanner (the reference app uses its own renderer, not a library).
/// Splits a message into renderable blocks; inline spans are handled by AttributedString's
/// own markdown parser, which is already in the standard library.
enum Markdown {
    enum Block {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case bullet(items: [AttributedString])
        case numbered(items: [AttributedString])
        case checklist(items: [(done: Bool, text: AttributedString)])
        case quote(AttributedString)
        case code(language: String?, text: String)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
    }

    /// Parse markdown into blocks. Unterminated fences are treated as code to the end,
    /// which is what a streaming response looks like mid-token.
    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: .newlines)
        var i = 0

        func flush(_ buffer: inout [String]) {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(inline(text)))
        }

        var paragraph: [String] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") {
                flush(&paragraph)
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // consume closing fence (or run off the end, harmlessly)
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            // Table: a header row followed by a |---|---| separator
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush(&paragraph)
                let header = cells(trimmed)
                var rows: [[AttributedString]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(&paragraph)
                blocks.append(.rule)
                i += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flush(&paragraph)
                blocks.append(.heading(level: level, inline(String(trimmed.dropFirst(level + 1)))))
                i += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flush(&paragraph)
                var body: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    body.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(1)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(inline(body.joined(separator: " "))))
                continue
            }

            if checkboxItem(trimmed) != nil {
                flush(&paragraph)
                var items: [(Bool, AttributedString)] = []
                while i < lines.count, let item = checkboxItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.checklist(items: items.map { (done: $0.0, text: $0.1) }))
                continue
            }

            if bulletItem(trimmed) != nil {
                flush(&paragraph)
                var items: [AttributedString] = []
                while i < lines.count, let item = bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(inline(item))
                    i += 1
                }
                blocks.append(.bullet(items: items))
                continue
            }

            if numberedItem(trimmed) != nil {
                flush(&paragraph)
                var items: [AttributedString] = []
                while i < lines.count, let item = numberedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(inline(item))
                    i += 1
                }
                blocks.append(.numbered(items: items))
                continue
            }

            if trimmed.isEmpty {
                flush(&paragraph)
            } else {
                paragraph.append(trimmed)
            }
            i += 1
        }
        flush(&paragraph)
        return blocks
    }

    // MARK: - Line classifiers

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            guard checkboxItem(line) == nil else { return nil }
            return String(line.dropFirst(2))
        }
        return nil
    }

    static func checkboxItem(_ line: String) -> (Bool, AttributedString)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(2)
            guard rest.hasPrefix("[") , rest.count > 3 else { return nil }
            let box = rest.dropFirst().prefix(1)
            guard rest.dropFirst(2).hasPrefix("] ") else { return nil }
            let done = box.lowercased() == "x"
            guard done || box == " " else { return nil }
            return (done, inline(String(rest.dropFirst(4))))
        }
        return nil
    }

    static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [AttributedString] {
        row.split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast(row.hasSuffix("|") ? 1 : 0)
            .map { inline($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Inline spans (bold, italic, links, `code`) via the standard-library markdown parser.
    /// Falls back to plain text when a half-streamed span does not parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(text)
    }
}
