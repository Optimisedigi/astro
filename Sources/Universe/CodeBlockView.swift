import AppKit
import SwiftUI

/// Fenced code with a language label, copy button and light syntax colouring.
/// The colouring is a small keyword/string/comment pass rather than a highlighting
/// dependency: a code block in a chat bubble is a few lines, not an editor.
/// simplification: no per-language grammars — one C-family keyword set covers the
/// languages we actually emit; swap in a real highlighter if that stops holding.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            Text(SyntaxHighlighter.highlight(code))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
        "import", "for", "while", "in", "switch", "case", "default", "try", "await", "async",
        "def", "from", "const", "function", "export", "public", "private", "static", "new",
        "true", "false", "nil", "null", "None", "self", "this", "throw", "throws", "extension",
    ]

    /// Colours comments, strings, numbers and keywords. Everything else stays `.primary`.
    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        for (index, line) in code.components(separatedBy: .newlines).enumerated() {
            if index > 0 { out += AttributedString("\n") }
            out += highlightLine(line)
        }
        return out
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            var comment = AttributedString(line)
            comment.foregroundColor = .secondary
            return comment
        }

        var out = AttributedString()
        var token = ""
        var inString: Character?

        func flushToken() {
            guard !token.isEmpty else { return }
            var piece = AttributedString(token)
            if keywords.contains(token) {
                piece.foregroundColor = .purple
            } else if Double(token) != nil {
                piece.foregroundColor = .orange
            }
            out += piece
            token = ""
        }

        for character in line {
            if let quote = inString {
                token.append(character)
                if character == quote {
                    var piece = AttributedString(token)
                    piece.foregroundColor = .green
                    out += piece
                    token = ""
                    inString = nil
                }
            } else if character == "\"" || character == "'" {
                flushToken()
                inString = character
                token.append(character)
            } else if character.isLetter || character.isNumber || character == "_" || character == "." {
                token.append(character)
            } else {
                flushToken()
                out += AttributedString(String(character))
            }
        }
        if inString != nil {
            var piece = AttributedString(token) // unterminated string mid-stream
            piece.foregroundColor = .green
            out += piece
        } else {
            flushToken()
        }
        return out
    }
}
