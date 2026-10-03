import Foundation
import OSLog

/// The one user-visible home for research HTML. It is independent of the chat
/// workspace, so research does not need to find or ask for a writable project.
enum ResearchReports {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }
    static var directory: URL { documentsDirectory.appendingPathComponent("astro", isDirectory: true) }
    private static let logger = Logger(subsystem: "com.universe.app", category: "ResearchReports")

    @discardableResult
    static func ensureDirectory(in documents: URL = documentsDirectory) throws -> URL {
        let started = Date()
        let root = documents.appendingPathComponent("astro", isDirectory: true).standardizedFileURL
        do {
            guard isUnredirected(root) else { throw ResearchReportError.folderUnavailable(root.path) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            guard isUnredirected(root), FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw ResearchReportError.folderUnavailable(root.path) }
            logger.info("Research folder ready path=\(root.path, privacy: .private) elapsed=\(Date().timeIntervalSince(started))")
            return root
        } catch {
            logger.error("Research folder unavailable path=\(root.path, privacy: .private) error=\(error.localizedDescription, privacy: .private) elapsed=\(Date().timeIntervalSince(started))")
            throw error
        }
    }

    /// Reject a redirected `astro` folder; an ordinary symlinked Documents
    /// directory (for example, an iCloud setup) can still be the user's home.
    private static func isUnredirected(_ root: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil else { return false }
        let expected = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL.path
        return root.resolvingSymlinksInPath().standardizedFileURL.path == expected
    }

    static func containsHTML(_ url: URL, in root: URL = directory) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isUnredirected(root), resolved.pathExtension.lowercased() == "html" else { return false }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = resolved.path
        return path.hasPrefix(rootPath + "/")
    }

    /// Stage the complete page first, then move it into view without replacing
    /// an existing file. A failed/retried report never overwrites another report.
    static func save(html: String, title: String, in documents: URL = documentsDirectory,
                     id: UUID = UUID()) throws -> URL {
        let started = Date()
        let root = try ensureDirectory(in: documents)
        let words = title.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        let slug = String(words.joined(separator: "-").prefix(70))
        let fileName = "\(slug.isEmpty ? "research" : slug)-\(id.uuidString.lowercased()).html"
        let destination = root.appendingPathComponent(fileName)
        let staging = root.appendingPathComponent(".\(id.uuidString).tmp")
        do {
            try Data(html.utf8).write(to: staging, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard containsHTML(destination, in: root) else { throw ResearchReportError.folderUnavailable(root.path) }
            try FileManager.default.moveItem(at: staging, to: destination)
            logger.info("Research saved path=\(destination.path, privacy: .private) bytes=\(html.utf8.count) elapsed=\(Date().timeIntervalSince(started))")
            return destination
        } catch {
            logger.error("Research save failed path=\(destination.path, privacy: .private) error=\(error.localizedDescription, privacy: .private) elapsed=\(Date().timeIntervalSince(started))")
            throw error
        }
    }
}
