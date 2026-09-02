import AppKit
import Foundation

/// Finder's Go to Folder, from the ask field: paste a path, press Enter.
enum FinderGo {
    /// The whole string is one existing local path — not a question that mentions one.
    static func existingURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .newlines) == nil else { return nil }

        if text.count >= 2,
           let q = text.first, (q == "\"" || q == "'"),
           text.last == q {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
        }

        guard let url = fileURL(from: text) else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return url
    }

    /// Folder → show its contents. File → select it. Always Finder, never the default app.
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        if isDir.boolValue {
            return NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
        return NSWorkspace.shared.selectFile(
            url.path,
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path
        )
    }

    private static func fileURL(from text: String) -> URL? {
        if text.lowercased().hasPrefix("file:") {
            if let parsed = URL(string: text), parsed.isFileURL {
                let host = parsed.host ?? ""
                guard host.isEmpty || host == "localhost" else { return nil }
                return parsed
            }
            // Unencoded spaces make URL(string:) fail; strip the scheme and treat as a path.
            var path = text
            for prefix in ["file://localhost", "file://", "file:"] {
                if path.lowercased().hasPrefix(prefix) {
                    path = String(path.dropFirst(prefix.count))
                    break
                }
            }
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }
}
