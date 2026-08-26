import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import os

private let logger = Logger(subsystem: "com.universe.app", category: "attachment")

/// An image the user dropped on the notch wing, travelling with one message.
///
/// Follows ggcoder's attachment model: the bytes live on disk and only the path
/// is persisted, so session JSON stays small while a follow-up turn can still
/// re-send the same image. `text` carries what Vision recognised, so a model
/// without vision — or a vision model reading small print — still gets the words.
struct ImageAttachment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// For display only. Never used to build a path: a dropped file names itself.
    var displayName: String
    var mediaType: String
    /// Absolute path inside the attachments directory; the file is named after `id`.
    var path: String
    /// Text recognised in the image. Untrusted — it is whatever was on screen.
    var text: String
    var pixelWidth: Int
    var pixelHeight: Int

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// The name with quotes and angle brackets removed, so a file called
    /// `"><script.png` cannot forge structure in the prompt block that names it.
    var safeLabel: String {
        displayName.filter { $0 != "\"" && $0 != "<" && $0 != ">" }
    }

    /// Base64 payload for an API request, read at send time so a long
    /// conversation doesn't hold every screenshot in memory. Nil if the file
    /// has been removed since the drop.
    func base64() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else {
            logger.warning("Attachment file missing at send time")
            return nil
        }
        return data.base64EncodedString()
    }
}

/// Turns dropped or pasted bytes into an `ImageAttachment`.
///
/// Everything here treats its input as hostile: the file type is decided by
/// decoding the bytes (never the extension), oversized files are refused before
/// they are read, the stored file is named after a UUID we generate, and the
/// recognised text is stripped of control characters and capped.
enum ImageAttachmentLoader {
    /// Refuse anything larger than this before reading it into memory.
    static let maxSourceBytes = 30 * 1024 * 1024

    /// Long-edge budget. Matches the per-image limit the Anthropic, OpenAI and
    /// Gemini vision endpoints all downscale to anyway — sending more just
    /// costs upload time and tokens.
    static let maxEdge = 1568

    /// Recognised text is prompt input, so it is capped like any other
    /// untrusted blob rather than allowed to fill the context window.
    static let maxTextCharacters = 4000

    /// At most this many images ride along with a single message.
    static let maxPerMessage = 4

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Universe/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// Build an attachment from raw bytes (a dragged image, or a paste).
    static func make(fromData data: Data, displayName: String) async -> ImageAttachment? {
        guard data.count <= maxSourceBytes else {
            logger.warning("Dropped data rejected: \(data.count, privacy: .public) bytes")
            return nil
        }
        // Decoding is the type check: an executable renamed to .png dies here.
        guard let decoded = decode(data) else {
            logger.warning("Dropped data is not a decodable image — ignored")
            return nil
        }

        let image = downscale(decoded)
        guard let png = encodePNG(image) else { return nil }

        let id = UUID()
        let fileURL = directory.appendingPathComponent("\(id.uuidString).png")
        do {
            try png.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            logger.error("Could not store attachment: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let text = await recognizeText(in: image)
        logger.info("Attached image \(image.width, privacy: .public)x\(image.height, privacy: .public), \(text.count, privacy: .public) chars of text")

        return ImageAttachment(
            id: id,
            displayName: sanitize(displayName, limit: 60),
            mediaType: "image/png",
            path: fileURL.path,
            text: text,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Raw bytes lifted off a pasteboard, ready to decode off the hot path.
    struct Payload {
        var name: String
        var data: Data
    }

    /// Copy every image the pasteboard offers into memory — file contents
    /// first, then raw image data — capped at `maxPerMessage`.
    ///
    /// Synchronous on purpose: a *drag* pasteboard is only guaranteed valid for
    /// the duration of `performDragOperation`, so the bytes must be taken now
    /// and decoded later, never the other way round.
    static func payloads(from pasteboard: NSPasteboard) -> [Payload] {
        var results: [Payload] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls.prefix(maxPerMessage) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size <= maxSourceBytes else {
                    logger.warning("Dropped file rejected: \(size, privacy: .public) bytes")
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                results.append(Payload(name: url.lastPathComponent, data: data))
            }
        }

        if results.isEmpty {
            for type in rawTypes {
                guard let data = pasteboard.data(forType: type), data.count <= maxSourceBytes else { continue }
                results.append(Payload(name: "screenshot.png", data: data))
                break
            }
        }

        // Last resort: let AppKit hand us the picture in whatever form the drag
        // source offered it (browsers and preview windows often do this).
        if results.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images.prefix(maxPerMessage) {
                guard let tiff = image.tiffRepresentation, tiff.count <= maxSourceBytes else { continue }
                results.append(Payload(name: "screenshot.png", data: tiff))
            }
        }
        return results
    }

    /// Decode, shrink, store and read text out of pasteboard bytes.
    static func attachments(from payloads: [Payload]) async -> [ImageAttachment] {
        var results: [ImageAttachment] = []
        for payload in payloads.prefix(maxPerMessage) {
            if let attachment = await make(fromData: payload.data, displayName: payload.name) {
                results.append(attachment)
            }
        }
        return results
    }

    /// Everything the notch wing accepts on a drag. Promised files are included
    /// because a screenshot dragged from its corner thumbnail is a promise, not
    /// a file that exists yet.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise)]
    }

    /// Raw image types worth reading straight off a pasteboard. Deliberately no
    /// PDF: `decode` would reject it, so accepting it would light the wing green
    /// and then attach nothing.
    private static let rawTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// True if this pasteboard carries something worth accepting, so the drop
    /// target can refuse the drag before the user lets go.
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) { return true }
        if pasteboard.availableType(from: rawTypes) != nil { return true }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return !promiseTypes(on: pasteboard).isEmpty
    }

    /// Image file promises on this pasteboard, if any.
    private static func promiseTypes(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return (receivers as? [NSFilePromiseReceiver] ?? []).filter { receiver in
            receiver.fileTypes.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }

    /// Promised image files on this pasteboard. Read during the drop; the files
    /// themselves arrive later via `fulfill`.
    static func promiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        Array(promiseTypes(on: pasteboard).prefix(maxPerMessage))
    }

    /// Ask the drag source to write its promised files into a scratch directory,
    /// then hand back the bytes. The scratch copies are deleted immediately: the
    /// attachment keeps its own copy.
    static func fulfill(
        _ receivers: [NSFilePromiseReceiver],
        completion: @escaping ([Payload]) -> Void
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("universe-drop-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else {
            completion([])
            return
        }

        let queue = OperationQueue()
        let group = DispatchGroup()
        var payloads: [Payload] = []
        let lock = NSLock()

        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: scratch, options: [:], operationQueue: queue) { url, error in
                defer { group.leave() }
                if let error {
                    logger.warning("Promised file failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size <= maxSourceBytes, let data = try? Data(contentsOf: url) else { return }
                lock.lock()
                payloads.append(Payload(name: url.lastPathComponent, data: data))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            try? FileManager.default.removeItem(at: scratch)
            completion(payloads)
        }
    }

    /// Delete the stored file for an attachment the user removed.
    static func discard(_ attachment: ImageAttachment) {
        try? FileManager.default.removeItem(at: attachment.fileURL)
    }

    // MARK: - Image handling

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let uttype = UTType(type), uttype.conforms(to: .image)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Shrink so the long edge fits `maxEdge`, preserving aspect ratio.
    static func downscale(_ image: CGImage) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxEdge else { return image }

        let scale = Double(maxEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Text extraction

    /// Recognised text, newline-joined in reading order.
    static func recognizeText(in image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: image)
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return sanitize(lines.joined(separator: "\n"), limit: maxTextCharacters)
        } catch {
            logger.warning("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Strip control characters (which can forge structure in a prompt or a log
    /// line) and cap the length.
    static func sanitize(_ raw: String, limit: Int) -> String {
        let cleaned = raw.unicodeScalars
            .filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        let string = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return string.count <= limit ? string : String(string.prefix(limit)) + "\n…[truncated]"
    }
}
