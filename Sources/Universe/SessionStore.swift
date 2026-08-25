import Foundation

/// Schema-compatible with Tama's sessions/<UUID>.json (SPEC.md §3).
struct Session: Codable, Identifiable {
    struct Message: Codable, Identifiable {
        var id = UUID()
        var role: String // "user" | "assistant"
        var timestamp = Date()
        var text: String
    }

    var id = UUID()
    var title: String
    var sessionType = "chat"
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [Message] = []
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Universe/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt } ?? []
    }

    func save(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: directory.appendingPathComponent("\(session.id.uuidString).json"), options: .atomic)
    }
}
