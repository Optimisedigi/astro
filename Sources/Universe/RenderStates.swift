import SwiftUI

/// Offscreen UI gate: rasterises our own view tree with `ImageRenderer`, so it needs
/// no window and no Screen Recording permission. Every registered state must produce a
/// PNG of the expected size that is not blank; anything else fails the run.
///
/// Run: `Universe --render-states <dir>`
@MainActor
enum RenderStates {
    struct State {
        let name: String
        let size: CGSize
        let view: AnyView

        init<V: View>(_ name: String, size: CGSize = CGSize(width: 420, height: 560), @ViewBuilder _ view: () -> V) {
            self.name = name
            self.size = size
            self.view = AnyView(view())
        }
    }

    /// Every UI state we assert on. Phases append their own list here.
    static var all: [State] { phase1States + phase2States + phase3States + onboardingStates + tabStates + moodStates + notchStates }

    static func run(directory: String) -> Bool {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("❌ cannot create \(dir.path): \(error.localizedDescription)")
            return false
        }

        var failures = 0
        for state in all {
            let url = dir.appendingPathComponent("\(state.name).png")
            switch render(state, to: url) {
            case .success:
                print("✅ \(state.name) → \(url.lastPathComponent)")
            case .failure(let reason):
                print("❌ \(state.name): \(reason)")
                failures += 1
            }
        }
        print(failures == 0 ? "\nRENDER-STATES PASSED (\(all.count) states)" : "\nRENDER-STATES FAILED (\(failures) failures)")
        return failures == 0
    }

    private enum Outcome { case success, failure(String) }

    private static func render(_ state: State, to url: URL) -> Outcome {
        let renderer = ImageRenderer(content: state.view.frame(width: state.size.width, height: state.size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return .failure("renderer produced no image")
        }
        guard abs(image.size.width - state.size.width) < 1, abs(image.size.height - state.size.height) < 1 else {
            return .failure("expected \(Int(state.size.width))×\(Int(state.size.height)), got \(Int(image.size.width))×\(Int(image.size.height))")
        }
        let ink = inkCoverage(rep)
        if ProcessInfo.processInfo.environment["RENDER_DEBUG"] != nil { print("   ink=\(ink)") }
        do { try png.write(to: url) } catch { return .failure("write failed: \(error.localizedDescription)") }
        guard ink > 0.01 else {
            return .failure(String(format: "image is effectively blank (%.3f%% ink)", ink * 100))
        }
        return .success
    }

    /// Share of sampled pixels that differ from the most common (background) colour.
    /// A blank or single-fill render scores ~0; any real content clears the floor.
    private static func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return 0 }
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let background = counts.values.max() else { return 0 }
        return Double(total - background) / Double(total)
    }
}
