import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "tool.imagegen")

/// Agent tool that draws a picture with OpenAI's image model, billed to the
/// user's ChatGPT sign-in (the same one chat uses — no API key). The picture
/// shows up in the reply (or in a preview window during a call) and a copy is
/// saved to ~/Pictures/Astro for the user to keep.
struct ImageGenerationTool: AgentTool {
    let name = "generate_image"
    let description = """
    Create a new image from a text description, using OpenAI's image model through the user's ChatGPT sign-in. \
    Use it whenever the user asks you to draw, generate, create, design or make a picture, image, illustration, \
    logo, icon, poster or artwork. Write a detailed prompt: subject, style, composition, colours, any text to \
    include. The image is shown to the user automatically and saved to their Pictures/Astro folder, so do not \
    describe it at length or invent links: say briefly that it is ready. Takes up to a minute.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prompt": ["type": "string", "description": "A detailed description of the image to create."],
            "shape": [
                "type": "string",
                "enum": Shape.allCases.map(\.rawValue),
                "description": "square (default), landscape (wide) or portrait (tall).",
            ],
        ],
        "required": ["prompt"],
    ]

    enum Shape: String, CaseIterable {
        case square, landscape, portrait

        /// Said in words too: the ChatGPT endpoint ignores `size` and picks
        /// its own shape unless the instructions name one.
        var wording: String {
            switch self {
            case .square: "a square image"
            case .landscape: "a wide landscape image"
            case .portrait: "a tall portrait image"
            }
        }

        var size: String {
            switch self {
            case .square: "1024x1024"
            case .landscape: "1536x1024"
            case .portrait: "1024x1536"
            }
        }
    }

    enum GenerationError: LocalizedError {
        case notSignedIn
        case http(Int, String)
        case noImage(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Image generation needs the ChatGPT sign-in. Tell the user to open AI Settings and sign in with ChatGPT."
            case let .http(code, body):
                "OpenAI's image service returned HTTP \(code): \(body.prefix(300))"
            case let .noImage(reason):
                "No image was produced. \(reason)"
            case .unreadable:
                "The image came back in a form that could not be opened."
            }
        }
    }

    /// Where a finished picture goes. A chat turn sets this around its own run
    /// so the picture lands in that reply. Anything else that can call the tool
    /// (a voice call, a scheduled routine) leaves it unset and gets a preview
    /// window, so a picture never lands in whichever chat happens to be open.
    @TaskLocal static var deliver: (@MainActor @Sendable (ImageAttachment) -> Void)?

    /// How long one picture may take before giving up. Generation streams
    /// progress events, but a large, detailed image can take over a minute.
    private static let timeout: TimeInterval = 180

    func run(input: [String: Any], workingDirectory _: URL) async throws -> String {
        guard let prompt = (input["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { throw ToolError.missingParam("prompt") }
        let shape = (input["shape"] as? String).flatMap(Shape.init(rawValue:)) ?? .square

        guard let credentials = try await OpenAIOAuth.validCredentials() else { throw GenerationError.notSignedIn }
        let model = await MainActor.run { Self.orchestratingModel() }

        let started = Date()
        logger.info("Generating \(shape.rawValue, privacy: .public) image with \(model, privacy: .public)")
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(prompt: prompt, shape: shape, model: model))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            logger.error("Image generation failed: HTTP \(http.statusCode, privacy: .public)")
            throw GenerationError.http(http.statusCode, body)
        }
        var lines: [String] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") { lines.append(line) }
        let png = try Self.imageData(fromEventLines: lines)

        let label = "Generated: " + prompt.prefix(50)
        guard let attachment = await ImageAttachmentLoader.make(fromData: png, displayName: String(label)) else {
            throw GenerationError.unreadable
        }
        let saved = Self.saveCopy(png, prompt: prompt)
        let deliver = Self.deliver
        await MainActor.run {
            if let deliver {
                deliver(attachment)
            } else {
                PanelController.shared.chatState.previewGeneratedImage(attachment)
            }
        }
        logger.info("Image generated in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")

        let location = saved.map { "saved to \($0.path)" } ?? "shown to the user (the copy to Pictures could not be written)"
        return "Image created (\(attachment.pixelWidth)×\(attachment.pixelHeight)) and \(location). It is already on screen."
    }

    /// The model that runs the request; the picture itself comes from the image
    /// tool it is forced to call. The user's pick if it is a GPT model.
    @MainActor
    static func orchestratingModel() -> String {
        let selected = ModelRegistry.shared.selectedModel
        if selected.provider == .openai { return selected.id }
        return ModelRegistry.models.first { $0.provider == .openai }?.id ?? "gpt-6-luna"
    }

    static func requestBody(prompt: String, shape: Shape, model: String) -> [String: Any] {
        [
            "model": model,
            "stream": true,
            "store": false,
            "input": [
                ["role": "system", "content": "Create the image the user describes, as \(shape.wording). Do not ask questions."],
                ["role": "user", "content": [["type": "input_text", "text": prompt]]],
            ],
            "tools": [["type": "image_generation", "size": shape.size, "output_format": "png"]],
            "tool_choice": ["type": "image_generation"],
        ]
    }

    /// Pull the finished picture out of the streamed events.
    static func imageData(fromEventLines lines: [String]) throws -> Data {
        var failure = "OpenAI did not say why."
        for line in lines {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any]
            else { continue }
            if let item = event["item"] as? [String: Any], item["type"] as? String == "image_generation_call",
               event["type"] as? String == "response.output_item.done" {
                guard let base64 = item["result"] as? String, let data = Data(base64Encoded: base64) else {
                    throw GenerationError.unreadable
                }
                return data
            }
            if let error = event["error"] as? [String: Any], let message = error["message"] as? String {
                failure = message
            } else if let response = event["response"] as? [String: Any],
                      let error = response["error"] as? [String: Any], let message = error["message"] as? String {
                failure = message
            }
        }
        throw GenerationError.noImage(failure)
    }

    /// A copy the user can find and use: ~/Pictures/Astro/<time> <prompt> <id>.png.
    /// Stage a complete image, then link it into place without overwriting a
    /// different image made in the same second. Foundation traps (not throws)
    /// when Data.write combines .atomic and .withoutOverwriting.
    static func saveCopy(_ png: Data, prompt: String, folder destination: URL? = nil, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let folder: URL
        if let destination {
            folder = destination
        } else {
            guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else { return nil }
            folder = pictures.appendingPathComponent("Astro", isDirectory: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        let url = folder.appendingPathComponent("\(stamp) \(fileSafe(prompt)) \(UUID().uuidString.prefix(8)).png")
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try png.write(to: staging, options: .atomic)
            try fm.linkItem(at: staging, to: url)
            return url
        } catch {
            logger.error("Could not save generated image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The start of the prompt as a file name: letters, digits and spaces only,
    /// so a prompt can never steer the path.
    static func fileSafe(_ prompt: String) -> String {
        let kept = prompt.prefix(40).map { $0.isLetter || $0.isNumber ? $0 : " " }
        let collapsed = String(kept).split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? "image" : collapsed
    }
}
