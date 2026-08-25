import Foundation

/// Offline proof that the agent loop executes tools end-to-end (no API key needed).
/// A scripted fake model requests write → read → bash; the real tools run on disk.
/// Run: `TamaClone --selftest`
enum SelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "✅ \(label)" : "❌ \(label)")
            if !condition { failures += 1 }
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("tamaclone-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1. Direct tool execution
        let registry = ToolRegistry.shared
        let writeResult = await registry.run(name: "write", input: [
            "file_path": "hello.txt", "content": "hello from the agent loop",
        ], workingDirectory: workspace)
        check(writeResult.contains("Wrote"), "write tool: \(writeResult)")

        let readResult = await registry.run(name: "read", input: ["file_path": "hello.txt"], workingDirectory: workspace)
        check(readResult.contains("hello from the agent loop"), "read tool returns written content")

        let editResult = await registry.run(name: "edit", input: [
            "file_path": "hello.txt", "old_text": "hello", "new_text": "goodbye",
        ], workingDirectory: workspace)
        check(editResult.contains("Edited"), "edit tool: \(editResult)")

        let bashResult = await registry.run(name: "bash", input: [
            "command": "cat hello.txt",
        ], workingDirectory: workspace)
        check(bashResult.contains("exit 0") && bashResult.contains("goodbye from the agent loop"),
              "bash tool sees edited file")

        let escapeResult = await registry.run(name: "read", input: ["file_path": "/etc/passwd"], workingDirectory: workspace)
        check(escapeResult.contains("escapes workspace"), "path escape outside workspace is blocked")

        // Sibling-prefix attack: absolute path whose string merely starts with the workspace path
        let sibling = workspace.deletingLastPathComponent().appendingPathComponent(workspace.lastPathComponent + "-evil", isDirectory: true)
        try? "secret".write(to: sibling.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let siblingResult = await registry.run(name: "read", input: [
            "file_path": sibling.appendingPathComponent("s.txt").path,
        ], workingDirectory: workspace)
        check(siblingResult.contains("escapes workspace"), "sibling-prefix escape is blocked")

        // Symlink attack: link inside workspace pointing outside must not pass
        try? FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        let symlinkResult = await registry.run(name: "read", input: ["file_path": "link.txt"], workingDirectory: workspace)
        check(symlinkResult.contains("escapes workspace"), "symlink escape is blocked")

        // 2. Full agent loop with a fake model: turn 1 requests write, turn 2 confirms.
        var turns = 0
        let fakeProvider: EventStreamProvider = { messages, _ in
            AsyncThrowingStream { continuation in
                turns += 1
                if turns == 1 {
                    continuation.yield(.toolUse(id: "toolu_test_1", name: "write", input: [
                        "file_path": "loop.txt", "content": "written by the agent loop",
                    ]))
                    continuation.yield(.stop(reason: "tool_use"))
                } else {
                    // Verify the loop fed back a tool_result
                    let lastMessage = messages.last?["content"] as? [[String: Any]]
                    let resultText = lastMessage?.first?["content"] as? String ?? ""
                    if resultText.contains("Wrote") {
                        continuation.yield(.text("File created."))
                    } else {
                        continuation.yield(.text("MISSING TOOL RESULT"))
                    }
                    continuation.yield(.stop(reason: "end_turn"))
                }
                continuation.finish()
            }
        }

        var streamedText = ""
        var toolActivities: [String] = []
        let loop = AgentLoop(workspace: workspace)
        do {
            try await loop.run(
                apiMessages: [["role": "user", "content": [["type": "text", "text": "make a file"]]]],
                streamProvider: fakeProvider,
                onText: { streamedText += $0 },
                onToolActivity: { toolActivities.append($0) }
            )
        } catch {
            check(false, "agent loop threw: \(error.localizedDescription)")
        }

        check(turns == 2, "loop ran 2 turns (tool_use → end_turn)")
        check(toolActivities.contains("write"), "loop dispatched the write tool")
        check(streamedText == "File created.", "loop fed tool_result back to the model")
        let onDisk = (try? String(contentsOf: workspace.appendingPathComponent("loop.txt"), encoding: .utf8)) ?? ""
        check(onDisk == "written by the agent loop", "file exists on disk with model-requested content")

        print(failures == 0 ? "\nSELFTEST PASSED" : "\nSELFTEST FAILED (\(failures) failures)")
        return failures == 0
    }
}
