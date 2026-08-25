import Foundation

/// A callable agent tool (SPEC.md §2 tool inventory — descriptions match Tama's).
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    /// Anthropic input_schema JSON.
    var inputSchema: [String: Any] { get }
    func run(input: [String: Any], workingDirectory: URL) async throws -> String
}

enum ToolError: LocalizedError {
    case missingParam(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .notFound(let p): return "No such file: \(p)"
        }
    }
}

private func stringParam(_ input: [String: Any], _ key: String) throws -> String {
    guard let value = input[key] as? String, !value.isEmpty else { throw ToolError.missingParam(key) }
    return value
}

/// Contain paths inside the working directory.
private func resolve(_ path: String, in wd: URL) throws -> URL {
    // resolvingSymlinksInPath defeats symlink escapes; trailing "/" defeats sibling-prefix matches
    let url = URL(fileURLWithPath: path, relativeTo: wd).standardized.resolvingSymlinksInPath()
    let wdPath = wd.standardized.resolvingSymlinksInPath().path
    guard url.path == wdPath || url.path.hasPrefix(wdPath + "/") else {
        throw ToolError.notFound("path escapes workspace: \(path)")
    }
    return url
}

struct BashTool: AgentTool {
    let name = "bash"
    let description = "Execute a bash command. Returns exit code and combined stdout/stderr."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["command": ["type": "string", "description": "The bash command to execute"]],
        "required": ["command"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let command = try stringParam(input, "command")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workingDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: "exit \(process.terminationStatus)\n\(output)")
        }
    }
}

struct ReadTool: AgentTool {
    let name = "read"
    let description = "Read a file's contents. Returns numbered lines (cat -n style). Output truncated to 2000 lines or 50KB."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["file_path": ["type": "string", "description": "The file path to read"]],
        "required": ["file_path"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let url = try resolve(stringParam(input, "file_path"), in: workingDirectory)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n").prefix(2000)
        var result = lines.enumerated().map { "\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n")
        if result.count > 50_000 { result = String(result.prefix(50_000)) + "\n[...truncated at 50KB...]" }
        return result
    }
}

struct WriteTool: AgentTool {
    let name = "write"
    let description = "Write content to a file. Creates parent directories if needed."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": ["type": "string"],
            "content": ["type": "string"],
        ],
        "required": ["file_path", "content"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let url = try resolve(stringParam(input, "file_path"), in: workingDirectory)
        let content = try stringParam(input, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) bytes to \(url.lastPathComponent)"
    }
}

struct EditTool: AgentTool {
    let name = "edit"
    let description = "Replace a specific text string in a file. The old_text must uniquely match exactly one location."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": ["type": "string"],
            "old_text": ["type": "string"],
            "new_text": ["type": "string"],
        ],
        "required": ["file_path", "old_text", "new_text"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let url = try resolve(stringParam(input, "file_path"), in: workingDirectory)
        let oldText = try stringParam(input, "old_text")
        let newText = input["new_text"] as? String ?? ""
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.notFound(url.path) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = text.components(separatedBy: oldText).count - 1
        guard count > 0 else { return "Error: old_text not found in file" }
        guard count == 1 else { return "Error: old_text matches \(count) locations — must be unique" }
        try text.replacingOccurrences(of: oldText, with: newText).write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(url.lastPathComponent)"
    }
}

final class ToolRegistry {
    static let shared = ToolRegistry()
    let tools: [any AgentTool] = [BashTool(), ReadTool(), WriteTool(), EditTool()]

    var schemas: [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema] }
    }

    func run(name: String, input: [String: Any], workingDirectory: URL) async -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return "Error: Unknown tool '\(name)'"
        }
        do {
            return try await tool.run(input: input, workingDirectory: workingDirectory)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
