import Foundation

extension SelfTest {
    /// Synthetic findings only: these checks don't perform searches, open the
    /// user's browser, or write into their real Documents folder.
    @MainActor
    static func runResearchReportChecks(check: (Bool, String) -> Void) async {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("astro-research-check-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        func decode(_ payload: [String: Any]) throws -> ResearchReport {
            try JSONDecoder().decode(ResearchReport.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let sample: [String: Any] = [
            "title": "Template check < & {{SCRIPT}}", "subtitle": "Synthetic test data, not research.",
            "verdict": "This is a template check. General findings should be easy to scan.",
            "date": "3 Oct 2026",
            "facts": (1...4).map { ["label": "Fact \($0)", "value": "Test", "note": "Fixture"] },
            "items": [["name": "General findings", "specs": [["label": "Detail", "value": "Literal <b>markup</b> & quotes \" stay text."]]]],
            "notes": ["These findings are test data."],
            "sources": [["title": "Example source", "url": "https://example.com/?a=1&b=2"]],
        ]
        do {
            let root = try ResearchReports.ensureDirectory(in: documents)
            check(root.lastPathComponent == "astro" && root.deletingLastPathComponent() == documents,
                  "research: new Documents location gets an astro folder")
            let sentinel = root.appendingPathComponent("existing.html")
            try "keep this report".write(to: sentinel, atomically: true, encoding: .utf8)
            _ = try ResearchReports.ensureDirectory(in: documents)
            check(try String(contentsOf: sentinel, encoding: .utf8) == "keep this report",
                  "research: repeated launch setup preserves existing reports")
            check(ResearchReports.directory == ResearchReports.documentsDirectory.appendingPathComponent("astro", isDirectory: true),
                  "research: production location is the current user's Documents/astro")

            let report = try decode(sample)
            let html = try ResearchReportRenderer.render(report)
            check(html.contains("class=\"card wide\"") && html.contains(".sheet{max-width:1160px") && !html.contains("<table>"),
                  "research: general research uses the supplied single-subject design and bundled CSS")
            check(html.contains("Template check &lt; &amp; {{SCRIPT}}") && html.contains("Literal &lt;b&gt;markup&lt;/b&gt;")
                    && !html.contains("<b>markup</b>"), "research: findings are escaped once and cannot replace template tokens")
            check(html.contains("https://example.com/?a=1&amp;b=2") && html.contains("rel=\"noopener noreferrer\""),
                  "research: source attributes are escaped and external links isolated")
            check(html.contains("script-src &#39;sha256-") && html.contains("default-src &#39;none&#39;")
                    && html.components(separatedBy: "<script>").count == 2,
                  "research: CSP permits only the bundled theme script")

            var videoSample = sample
            videoSample["items"] = [["name": "Video placement", "specs": [["label": "Detail", "value": "Test data"]],
                "video": ["title": "Video search (test data)", "url": "https://www.youtube.com/results?search_query=research", "note": "Search link; no specific video verified."]]]
            let videoHTML = try ResearchReportRenderer.render(decode(videoSample))
            check(videoHTML.contains("<div class=\"side\"><a class=\"video\"") && videoHTML.contains("Search link; no specific video verified."),
                  "research: optional single-subject video uses the supplied sidebar layout with its caveat")

            var comparisonSample = sample
            comparisonSample["items"] = [
                ["name": "Option A", "specs": [["label": "Detail", "value": "First"]], "pros": ["A benefit"], "cons": ["A tradeoff"]],
                ["name": "Option B", "specs": [["label": "Detail", "value": "Second"]]],
            ]
            comparisonSample["comparison"] = ["columns": ["Option A", "Option B"], "rows": [
                ["feature": "An objective metric", "values": ["2", "1"], "winner": 0],
                ["feature": "Subjective preference", "values": ["A", "B"], "winner": NSNull()],
            ]]
            let multi = try ResearchReportRenderer.render(decode(comparisonSample))
            check(multi.contains("class=\"items\"") && multi.contains("class=\"table-scroll\"")
                    && multi.contains("scope=\"row\"") && multi.components(separatedBy: "class=\"win\"").count == 2,
                  "research: comparisons retain cards, a scrollable accessible table, and only objective winner marks")

            var openedURLs: [URL] = []
            let tool = ResearchReportTool(documentsDirectory: documents, openURL: { url in
                openedURLs.append(url)
                return FileManager.default.fileExists(atPath: url.path)
            })
            let result = try await tool.run(input: ["report": sample], workingDirectory: documents)
            let resultObject = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
            let savedPath = resultObject?["file_path"] as? String ?? ""
            check(resultObject?["saved"] as? Bool == true && resultObject?["opened_in_browser"] as? Bool == true
                    && openedURLs.count == 1 && openedURLs.first?.path == savedPath,
                  "research: one tool call saves the complete HTML before handing its local URL to the browser")
            let saved = try String(contentsOfFile: savedPath, encoding: .utf8)
            check(saved == html && ResearchReports.containsHTML(URL(fileURLWithPath: savedPath), in: root),
                  "research: saved HTML is self-contained in Documents/astro")
            _ = try await tool.run(input: ["report": comparisonSample, "open_in_browser": false], workingDirectory: documents)
            check(openedURLs.count == 1, "research: explicit save-only requests do not open the browser")

            let fixedID = UUID()
            let original = try ResearchReports.save(html: html, title: "Same title", in: documents, id: fixedID)
            do {
                _ = try ResearchReports.save(html: "replacement", title: "Same title", in: documents, id: fixedID)
                check(false, "research: filename collisions refuse overwrite")
            } catch {
                check(try String(contentsOf: original, encoding: .utf8) == html,
                      "research: filename collisions refuse overwrite and preserve the original")
            }
            let another = try ResearchReports.save(html: html, title: "Same title", in: documents)
            check(another != original, "research: repeated titles get distinct report files")

            let browserFailure = ResearchReportTool(documentsDirectory: documents, openURL: { _ in false })
            let failure = try await browserFailure.run(input: ["report": sample], workingDirectory: documents)
            check(failure.hasPrefix("Error: Saved research HTML at ") && failure.contains("could not open"),
                  "research: browser failure reports the saved file instead of claiming it opened")
            let failedBrowserPath = failure.replacingOccurrences(of: "Error: Saved research HTML at ", with: "")
                .components(separatedBy: ", but the default browser").first ?? ""
            check(FileManager.default.fileExists(atPath: failedBrowserPath), "research: browser failure leaves the completed report available")
            let filesBeforeCancellation = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            let cancelled = Task { @MainActor in try await tool.run(input: ["report": sample], workingDirectory: documents) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                check(false, "research: cancellation before save is respected")
            } catch is CancellationError {
                let filesAfterCancellation = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                check(openedURLs.count == 1 && filesAfterCancellation == filesBeforeCancellation,
                      "research: cancellation before save creates no file and avoids a browser handoff")
            }

            let workspace = documents.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let write = WriteTool(reportsDirectory: root)
            let read = ReadTool(reportsDirectory: root)
            let edit = EditTool(reportsDirectory: root)
            let allowed = root.appendingPathComponent("editable.html")
            _ = try await write.run(input: ["file_path": allowed.path, "content": "before"], workingDirectory: workspace)
            _ = try await edit.run(input: ["file_path": allowed.path, "old_text": "before", "new_text": "after"], workingDirectory: workspace)
            let readBack = try await read.run(input: ["file_path": allowed.path], workingDirectory: workspace)
            check(readBack.contains("after"), "research: normal file tools can create, read and edit HTML outside the chat workspace")
            for path in [root.appendingPathComponent("not-html.txt"), documents.appendingPathComponent("outside.html"),
                         documents.appendingPathComponent("astro-other/escape.html")] {
                do {
                    _ = try await write.run(input: ["file_path": path.path, "content": "blocked"], workingDirectory: workspace)
                    check(false, "research: non-HTML and sibling paths remain blocked")
                } catch {
                    check(!FileManager.default.fileExists(atPath: path.path), "research: non-HTML and sibling paths remain blocked")
                }
            }
            let escaped = root.appendingPathComponent("link.html")
            try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: documents.appendingPathComponent("outside.html"))
            do {
                _ = try await write.run(input: ["file_path": escaped.path, "content": "blocked"], workingDirectory: workspace)
                check(false, "research: HTML symlink escapes remain blocked")
            } catch {
                check(!FileManager.default.fileExists(atPath: documents.appendingPathComponent("outside.html").path),
                      "research: HTML symlink escapes remain blocked")
            }
            let redirectParent = documents.appendingPathComponent("redirect", isDirectory: true)
            try FileManager.default.createDirectory(at: redirectParent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: redirectParent.appendingPathComponent("astro"), withDestinationURL: workspace)
            do {
                _ = try ResearchReports.ensureDirectory(in: redirectParent)
                check(false, "research: redirected report folders are rejected")
            } catch {
                check(true, "research: redirected report folders are rejected")
            }
            for mutation in ["bad-link", "bad-facts", "bad-columns", "bad-winner", "bad-thumb", "big-input", "bad-open"] {
                var invalid = sample
                var input: [String: Any]
                switch mutation {
                case "bad-link": invalid["sources"] = [["title": "Not a web link", "url": "file:///etc/passwd"]]
                case "bad-facts": invalid["facts"] = []
                case "bad-columns": invalid["comparison"] = ["columns": ["A", "B"], "rows": [["feature": "Mismatch", "values": ["A"]]]]
                case "bad-winner": invalid["comparison"] = ["columns": ["A", "B"], "rows": [["feature": "Invalid", "values": ["A", "B"], "winner": 2]]]
                case "bad-thumb": invalid["items"] = [["name": "Video", "specs": [["label": "Detail", "value": "Test"]], "video": ["title": "Video", "url": "https://example.com", "thumb": "https://example.com/image.png"]]]
                case "big-input": invalid["verdict"] = String(repeating: "x", count: 262_145)
                default: break
                }
                let filesBeforeInvalid = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                input = ["report": invalid]
                if mutation == "bad-open" { input["open_in_browser"] = 1 }
                do {
                    _ = try await tool.run(input: input, workingDirectory: documents)
                    check(false, "research: \(mutation) is rejected before saving or opening")
                } catch {
                    let filesAfterInvalid = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                    check(openedURLs.count == 1 && filesAfterInvalid == filesBeforeInvalid,
                          "research: \(mutation) is rejected before saving or opening")
                }
            }
            check(ToolRegistry.shared.schemas.contains { $0["name"] as? String == tool.name }
                    && OpenAIRealtimeCallSession.functionTools(from: .shared).contains { $0["name"] as? String == tool.name },
                  "research: HTML creation is a normal tool in chat and realtime calls")
            check(ClaudeService.chatSystemPromptForTesting.contains("create_research_html")
                    && buildCallSystemPrompt().contains("create_research_html"),
                  "research: chat and voice prompts specify the built-in workflow without a skill")
        } catch {
            check(false, "research workflow threw: \(error.localizedDescription)")
        }
    }
}
