import SwiftUI

// A SwiftUI port of "voice-glow" (VoiceBeam) by Jakub Antalik, MIT licence.
//
// Wraps a view and overlays a sound-reactive glow along its bottom edge: a
// centred, colourful beam of seven soft lobes that rises and blooms with the
// voice, traced by a luminous band with chromatic fringes. While
// `processing`, the lobes gather into one compact beam that travels the
// range, left to right and back.
//
// The port keeps the library's `default` type on its dark theme. Every layer
// the web version paints with CSS (the 1px edge stroke, the inner light, the
// blurred bloom, the band canvas) is drawn into one Canvas per frame from
// the values the driver computes, exactly where the web driver would write
// them as CSS custom properties.

// MARK: - Public surface

enum VoiceGlowColors: CaseIterable {
    case colorful, mono, ocean, sunset, forest, candy, ice, gold

    /// Seven lobe colours (centre first, then the pairs outward), the dark
    /// palettes of the library's `voicePalettes`.
    var palette: [SIMD3<Double>] {
        let raw: [(Double, Double, Double)]
        switch self {
        case .colorful:
            raw = [(255, 70, 120), (60, 190, 255), (175, 70, 255), (60, 220, 130),
                   (255, 150, 40), (90, 100, 255), (40, 200, 190)]
        case .mono:
            raw = [(215, 215, 215), (180, 180, 180), (190, 190, 190), (160, 160, 160),
                   (170, 170, 170), (150, 150, 150), (155, 155, 155)]
        case .ocean:
            raw = [(80, 140, 255), (40, 200, 230), (120, 90, 255), (30, 170, 210),
                   (160, 80, 240), (60, 110, 255), (40, 190, 180)]
        case .sunset:
            raw = [(255, 110, 60), (255, 180, 40), (255, 60, 90), (255, 210, 80),
                   (240, 70, 140), (255, 140, 50), (230, 50, 110)]
        case .forest:
            raw = [(70, 220, 120), (40, 200, 180), (140, 230, 80), (30, 170, 140),
                   (190, 235, 70), (50, 190, 110), (30, 150, 120)]
        case .candy:
            raw = [(255, 90, 170), (255, 120, 220), (210, 80, 255), (255, 150, 190),
                   (180, 110, 255), (255, 70, 140), (230, 100, 240)]
        case .ice:
            raw = [(150, 230, 255), (90, 200, 255), (190, 240, 255), (120, 190, 255),
                   (160, 220, 250), (80, 170, 255), (200, 235, 255)]
        case .gold:
            raw = [(255, 200, 70), (255, 170, 40), (255, 220, 110), (240, 150, 30),
                   (255, 235, 140), (230, 160, 40), (250, 210, 90)]
        }
        return raw.map { SIMD3($0.0 / 255, $0.1 / 255, $0.2 / 255) }
    }
}

struct VoiceGlow<Content: View>: View {
    private let level: () -> Double
    private let processing: Bool
    private let active: Bool
    private let cornerRadius: CGFloat
    private let colorVariant: VoiceGlowColors
    private let strength: Double
    private let content: Content
    private let params = VoiceGlowParams.default

    @State private var driver = VoiceGlowDriver()
    @State private var fullyFaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(level: @escaping () -> Double,
         processing: Bool = false,
         active: Bool = true,
         cornerRadius: CGFloat = 20,
         colorVariant: VoiceGlowColors = .colorful,
         strength: Double = 1,
         @ViewBuilder content: () -> Content) {
        self.level = level
        self.processing = processing
        self.active = active
        self.cornerRadius = cornerRadius
        self.colorVariant = colorVariant
        self.strength = strength
        self.content = content()
    }

    var body: some View {
        content
            .overlay { glow }
            .onChange(of: active) { _, isActive in
                if isActive { fullyFaded = false }
            }
    }

    @ViewBuilder
    private var glow: some View {
        let style = VoiceGlowStyle(params: params, colors: colorVariant,
                                   cornerRadius: cornerRadius, strength: strength)
        Group {
            if reduceMotion {
                // Static and calm: the idle glow at its mid-breath (or the
                // gathered beam, held at the centre, while processing), no
                // voice reaction, flow, hue drift or fades.
                if active {
                    VoiceGlowCanvas(frame: VoiceGlowDriver.staticFrame(processing: processing, params: params),
                                    style: style)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active && fullyFaded)) { timeline in
                    let frame = driver.advance(to: timeline.date, input: level(), processing: processing,
                                               active: active, params: params,
                                               staticColors: colorVariant == .mono)
                    let faded = !active && frame.opacity <= 0
                    Group {
                        if frame.opacity > 0 {
                            VoiceGlowCanvas(frame: frame, style: style)
                        } else {
                            Color.clear
                        }
                    }
                    .onChange(of: faded, initial: true) { _, value in
                        if fullyFaded != value { fullyFaded = value }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Tuning

/// The library's `default` type on its dark theme (presets.ts `voiceDefaults`,
/// VoiceBeam.tsx prop defaults, styles.ts `themePresets.dark`, and the
/// `default` type's brightness lift).
struct VoiceGlowParams {
    // Input chain.
    /// Gain on the incoming level before the gate. The library only applies
    /// `BASE_GAIN (5) × sensitivity (3.1)` to the raw RMS it measures from a
    /// MediaStream; a caller-supplied 0–1 `level` is used as is. Callers
    /// here already hand in a normalised 0–1 loudness, so this stays 1 —
    /// use `rawRMSGain` if you feed a raw RMS instead.
    var gain: Double = 1
    static let rawRMSGain: Double = 5 * 3.1
    var threshold: Double = 0.015
    var attack: Double = 0.325
    var release: Double = 0.86

    // Reaction shape.
    var idle: Double = 0.18
    var breatheDuration: Double = 5.2
    var reach: Double = 1.2
    var spread: Double = 1.05
    var bands: Bool = true
    var flow: Double = 48
    var lobeSpacing: Double = 0.85
    var bend: Double = 60

    // Band line.
    var bandStrength: Double = 1.55
    var bandWidth: Double = 2.15
    var bandPosition: Double = 0.35
    var bandCurve: Double = 1.75
    var bandSpread: Double = 0.87
    var bandSkew: Double = 0.12
    var bandOffset: Double = -27
    var bandTail: Double = 0.59
    var bandTailPosition: Double = 0.67
    var bandTailCurve: Double = 2.4
    var bandTailOverflow: Double = 15
    var bandAberration: Double = 0.89
    /// Band colours (dark): core, fringe above, mid, fringe below.
    var bandCore = SIMD3<Double>(1, 1, 1)
    var bandAbove = SIMD3<Double>(255, 70, 80) / 255
    var bandMid = SIMD3<Double>(90, 255, 150) / 255
    var bandBelow = SIMD3<Double>(80, 140, 255) / 255

    // Geometry.
    var glowSize: Double = 1
    var glowWidth: Double = 0.65
    var glowHeight: Double = 1.25
    var rangeWidth: Double = 0.75
    var rangeHeight: Double = 1
    var softness: Double = 1.07
    var coreSize: Double = 1

    // Processing.
    var processingDuration: Double = 1.1
    var processingLevel: Double = 0.55
    var processingEase: Double = 0.6
    var processingTravel: Double = 1.55
    var processingCurve: Double = 2.1
    var cornerFollow: Double = 0.45

    // Colour (dark theme).
    var hueRange: Double = 24
    var hueDuration: Double = 12
    var brightness: Double = 1.15
    var saturation: Double = 1.2
    var strokeOpacity: Double = 1.16
    var innerOpacity: Double = 0.47
    var bloomOpacity: Double = 0.89
    var innerShadowAlpha: Double = 0.1

    // Fades (the CSS fade-in / fade-out keyframes).
    var fadeIn: Double = 0.6
    var fadeOut: Double = 0.5

    static let `default` = VoiceGlowParams()
}

/// Lobe geometry in px for the ~350px reference host (styles.ts `voiceLobes`).
struct VoiceGlowLobe {
    let x: Double, w: Double, h: Double, band: Int

    static let all: [VoiceGlowLobe] = [
        .init(x: 0, w: 74, h: 46, band: 0),
        .init(x: -36, w: 54, h: 40, band: 1),
        .init(x: 36, w: 54, h: 40, band: 1),
        .init(x: -72, w: 48, h: 32, band: 2),
        .init(x: 72, w: 48, h: 32, band: 2),
        .init(x: -108, w: 42, h: 26, band: 1),
        .init(x: 108, w: 42, h: 26, band: 1),
    ]
    static let spacing: Double = 36
    static var span: Double { spacing * Double(all.count) }
}

// MARK: - Driver

/// Everything the renderer needs for one frame (the web driver's CSS vars).
struct VoiceGlowFrame {
    var opacity: Double = 1     // fade in/out, eased
    var level: Double = 0       // smoothed envelope
    var glow: Double = 0.4      // presence
    var h: Double = 0.8         // height multiplier
    var w: Double = 1           // spread multiplier
    var cx: Double = 0          // beam offset, px (processing travel)
    var cy: Double = 0          // beam lift along the corner arc, px
    var mw: Double = 1          // range width while processing
    var lift: Double = 0        // bend height, px
    var bendA: Double = 0       // bend strength 0–1 (band opacity)
    var morph: Double = 0       // processing blend, eased
    var hue: Double = 0         // degrees
    var lobeX = [Double](repeating: 0, count: 7)
    var lobeL = [Double](repeating: 1, count: 7)
    var lobeY = [Double](repeating: 0, count: 7)
}

/// Envelope and animation state, persisted across frames (held in @State).
final class VoiceGlowDriver {
    private(set) var level: Double = 0
    private var bands: [Double] = [0, 0, 0]
    private var phase: Double = 0
    private var scanA: Double = 0
    private var scanT: Double = 0
    private var t: Double = 0
    private var fade: Double = 0
    private var lastDate: Date?

    // MARK: Pure steps

    /// Noise gate then soft saturation, so a shout rounds off instead of clipping.
    static func shape(_ raw: Double, threshold: Double) -> Double {
        if raw <= threshold { return 0 }
        let x = (raw - threshold) / max(0.001, 1 - threshold)
        return clamp01((1 - exp(-3 * x)) / (1 - exp(-3)))
    }

    /// One-pole follower: fast up (attack), slow down (release).
    static func follow(_ prev: Double, _ target: Double, dt: Double, attack: Double, release: Double) -> Double {
        let tau = target > prev ? attack : release
        let a = 1 - exp(-dt / max(0.001, tau))
        return prev + (target - prev) * a
    }

    /// One envelope step of the input chain: clamp the 0–1 input, apply the
    /// gain, gate and shape it, then follow it with the attack/release
    /// envelope over `dt` seconds.
    static func step(envelope: Double, input: Double, dt: Double, params: VoiceGlowParams) -> Double {
        let target = shape(clamp01(input) * params.gain, threshold: params.threshold)
        return follow(envelope, target, dt: dt, attack: params.attack, release: params.release)
    }

    // MARK: Frame

    /// Advance the state to `date` and compute the frame (voiceDriver.ts `frame`).
    func advance(to date: Date, input: Double, processing: Bool, active: Bool,
                 params p: VoiceGlowParams, staticColors: Bool) -> VoiceGlowFrame {
        let dt: Double
        if let last = lastDate {
            let gap = date.timeIntervalSince(last)
            // A resume after a pause must not integrate the gap.
            dt = gap > 0.25 ? 1.0 / 60 : max(0, min(0.05, gap))
        } else {
            dt = 1.0 / 60
        }
        lastDate = date
        t += dt

        // Fade (CSS keyframes: 0.6 s in, 0.5 s out).
        fade = active ? min(1, fade + dt / p.fadeIn) : max(0, fade - dt / p.fadeOut)

        // Raw level; no spectrum, so the bands get slow out-of-phase wobbles.
        let raw = clamp01(input.isFinite ? input : 0)
        let rawBands = [raw,
                        raw * (0.72 + 0.28 * sin(t * 9.1)),
                        raw * (0.6 + 0.4 * sin(t * 13.7 + 2))]

        level = Self.step(envelope: level, input: raw, dt: dt, params: p)
        for b in 0..<3 {
            let bt = Self.shape(clamp01(rawBands[b]) * p.gain, threshold: p.threshold * 0.6)
            bands[b] = Self.follow(bands[b], bt, dt: dt, attack: p.attack, release: p.release * 1.15)
        }

        // Processing travel: a fresh start begins mid-pass, at the centre.
        let duration = max(0.05, p.processingDuration)
        if processing && scanA < 0.001 && scanT == 0 { scanT = duration / 2 }
        let ease = max(0.05, p.processingEase)
        scanA = Self.follow(scanA, processing ? 1 : 0, dt: dt, attack: ease * 0.9, release: ease * 0.8)
        if processing { scanT += dt } else if scanA < 0.001 { scanT = 0 }
        let morph = smoothstep(scanA)

        let passes = scanT / duration
        let passIndex = floor(passes)
        let u = passes - passIndex
        let k = max(1, p.processingCurve)
        let eased = u < 0.5 ? 0.5 * pow(2 * u, k) : 1 - 0.5 * pow(2 - 2 * u, k)
        let pass = Int(passIndex) % 2 == 0 ? 2 * eased - 1 : 1 - 2 * eased

        let breathe = 0.5 + 0.5 * sin(2 * .pi * t / max(0.2, p.breatheDuration))
        var f = Self.shapeFrame(level: level, bands: bands, morph: morph, pass: pass,
                                breathe: breathe, phase: phase, params: p)

        // Flow: the spectrum slides sideways while a voice is heard.
        let span = VoiceGlowLobe.span * p.lobeSpacing
        if p.flow != 0 {
            phase = (phase + p.flow * f.effective * dt).truncatingRemainder(dividingBy: span)
            if phase < 0 { phase += span }
        }

        f.frame.opacity = smoothstep(fade)
        f.frame.hue = staticColors || p.hueRange == 0
            ? 0
            : -p.hueRange + 2 * p.hueRange * (1 - cos(2 * .pi * t / max(0.5, p.hueDuration))) / 2
        return f.frame
    }

    /// The reduced-motion frame: idle at mid-breath, or the gathered beam
    /// resting at the centre while processing.
    static func staticFrame(processing: Bool, params p: VoiceGlowParams) -> VoiceGlowFrame {
        shapeFrame(level: 0, bands: [0, 0, 0], morph: processing ? 1 : 0, pass: 0,
                   breathe: 0.5, phase: 0, params: p).frame
    }

    private static func shapeFrame(level: Double, bands: [Double], morph: Double, pass: Double,
                                   breathe: Double, phase: Double,
                                   params p: VoiceGlowParams) -> (frame: VoiceGlowFrame, effective: Double) {
        let span = VoiceGlowLobe.span * p.lobeSpacing
        let travel = span / 2 * p.processingTravel
        let cx = morph * travel * pass
        let gather = 1 - morph * 0.6
        let maskWidth = 1 - morph * 0.45
        let passWidth = 1 + morph * 0.3 * (1 - pass * pass)

        // Idle breathing folded under the voice; the processing hold waits
        // for the first quarter of the morph.
        let voiced = level + (1 - level) * p.idle * breathe
        let held = smoothstep(clamp01((morph - 0.25) / 0.75))
        let eff = max(voiced, p.processingLevel * held)

        var f = VoiceGlowFrame()
        f.level = level
        f.morph = morph
        f.glow = 0.15 + 0.85 * eff
        f.h = 0.5 + p.reach * eff
        f.w = (0.85 + p.spread * eff) * passWidth
        f.cx = cx
        f.mw = maskWidth
        f.lift = max(0, p.bend * eff)
        f.bendA = p.bend > 0 ? min(1, f.lift / p.bend) : 0
        for (i, lobe) in VoiceGlowLobe.all.enumerated() {
            let x = wrapX(lobe.x * p.lobeSpacing + phase, span: span)
            let bandLift = p.bands ? 0.6 + 0.7 * bands[lobe.band] : 1
            f.lobeX[i] = x * gather
            f.lobeL[i] = bandLift * edgeEnvelope(x, span: span)
        }
        return (f, eff)
    }
}

// MARK: - Geometry helpers (voiceDriver.ts)

private func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }
private func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

private func wrapX(_ x: Double, span: Double) -> Double {
    let half = span / 2
    var m = (x + half).truncatingRemainder(dividingBy: span)
    if m < 0 { m += span }
    return m - half
}

private func edgeEnvelope(_ x: Double, span: Double) -> Double {
    let t = x / (span / 2 + 4)
    return max(0, 1 - t * t)
}

private func paintedRadius(_ r: Double, _ cw: Double, _ ch: Double) -> Double {
    max(0, min(r, cw / 2, ch / 2))
}

private func cornerLift(_ x: Double, _ cw: Double, _ radius: Double, influence: Double = 0) -> Double {
    if radius <= 0 { return 0 }
    let d = min(x, cw - x) - influence
    if d >= radius { return 0 }
    if d <= 0 { return radius }
    let dx = radius - d
    return radius - (max(0, radius * radius - dx * dx)).squareRoot()
}

private func bell(_ t: Double, p: Double, sigma: Double, skew: Double) -> Double {
    let side = t < 0 ? 1 - skew : 1 + skew
    let s = max(0.05, sigma * side)
    let v = exp(-pow(abs(t) / s, p))
    let tail = exp(-pow(1 / s, p))
    return max(0, (v - tail) / (1 - tail))
}

private func tailLift(_ dist: Double, edge: Double, lift: Double, position: Double, curve: Double) -> Double {
    if lift <= 0 || edge <= 0 { return 0 }
    let start = edge * max(0, min(0.98, position))
    if dist <= start { return 0 }
    let u = min(1, (dist - start) / max(1, edge - start))
    return lift * pow(u, max(0.5, curve))
}

/// CSS `hue-rotate() brightness() saturate()` on an sRGB colour, per the
/// Filter Effects matrices, clamped after each step as the filter chain is.
private func cssFilter(_ c: SIMD3<Double>, hue: Double, brightness: Double, saturation s: Double) -> SIMD3<Double> {
    func clamp(_ v: SIMD3<Double>) -> SIMD3<Double> { v.clamped(lowerBound: .zero, upperBound: .one) }
    var v = c
    if hue != 0 {
        let a = hue * .pi / 180, co = cos(a), si = sin(a)
        v = clamp(SIMD3(
            (0.213 + co * 0.787 - si * 0.213) * v.x + (0.715 - co * 0.715 - si * 0.715) * v.y + (0.072 - co * 0.072 + si * 0.928) * v.z,
            (0.213 - co * 0.213 + si * 0.143) * v.x + (0.715 + co * 0.285 + si * 0.140) * v.y + (0.072 - co * 0.072 - si * 0.283) * v.z,
            (0.213 - co * 0.213 - si * 0.787) * v.x + (0.715 - co * 0.715 + si * 0.715) * v.y + (0.072 + co * 0.928 + si * 0.072) * v.z))
    }
    v = clamp(v * brightness)
    v = clamp(SIMD3(
        (0.213 + 0.787 * s) * v.x + (0.715 - 0.715 * s) * v.y + (0.072 - 0.072 * s) * v.z,
        (0.213 - 0.213 * s) * v.x + (0.715 + 0.285 * s) * v.y + (0.072 - 0.072 * s) * v.z,
        (0.213 - 0.213 * s) * v.x + (0.715 - 0.715 * s) * v.y + (0.072 + 0.928 * s) * v.z))
    return v
}

private func rgb(_ v: SIMD3<Double>, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: v.x, green: v.y, blue: v.z, opacity: alpha)
}

// MARK: - Rendering (styles.ts + drawBand)

struct VoiceGlowStyle {
    let params: VoiceGlowParams
    let colors: VoiceGlowColors
    let cornerRadius: CGFloat
    let strength: Double
}

private struct VoiceGlowCanvas: View {
    let frame: VoiceGlowFrame
    let style: VoiceGlowStyle

    var body: some View {
        Canvas { ctx, size in
            VoiceGlowRenderer(frame: frame, style: style, size: size).draw(in: ctx)
        }
    }
}

private struct VoiceGlowRenderer {
    let f: VoiceGlowFrame
    let p: VoiceGlowParams
    let style: VoiceGlowStyle
    let W: Double, H: Double
    let radius: Double
    let colors: [SIMD3<Double>]
    let bounds: CGRect

    init(frame: VoiceGlowFrame, style: VoiceGlowStyle, size: CGSize) {
        p = style.params
        self.style = style
        W = size.width
        H = size.height
        let r = paintedRadius(style.cornerRadius, size.width, size.height)
        radius = r
        // While processing, the beam and every lobe lift along the corner
        // arcs as they pass through them (needs the host width, so it is
        // resolved here rather than in the driver).
        var fr = frame
        let blend = frame.morph * style.params.cornerFollow
        if blend > 0 {
            let reach = 30 * frame.w
            fr.cy = -cornerLift(W / 2 + frame.cx * frame.w, W, r, influence: reach * 1.4) * blend
            for i in fr.lobeY.indices {
                let x = W / 2 + (frame.cx + frame.lobeX[i]) * frame.w
                fr.lobeY[i] = -cornerLift(x, W, r, influence: reach) * blend
            }
        }
        f = fr
        bounds = CGRect(origin: .zero, size: size)
        let (hue, b, s) = (frame.hue, style.params.brightness, style.params.saturation)
        colors = style.colors.palette.map { cssFilter($0, hue: hue, brightness: b, saturation: s) }
    }

    private var beamX: Double { W / 2 + f.cx * f.w }
    private var fadeStop: Double { (max(40, min(95, 70 * p.softness))).rounded() / 100 }

    func draw(in context: GraphicsContext) {
        guard W > 1, H > 1, f.opacity > 0 else { return }
        var ctx = context
        ctx.clip(to: Path(roundedRect: bounds, cornerRadius: radius, style: .circular))

        let monoMul = style.colors == .mono ? 0.6 : 1
        let strength = clamp01(style.strength)
        func layerOpacity(_ preset: Double) -> Double {
            min(1, f.opacity * f.glow * preset * monoMul * strength)
        }

        // Inner light (z 1): soft light inside the element, only near its
        // edges, masked to the level-driven ellipse.
        var inner = ctx
        inner.opacity = layerOpacity(p.innerOpacity)
        inner.drawLayer { l in
            drawLobes(l, alpha: 0.46, sw: p.glowWidth * 0.9, sh: p.glowHeight * 0.9, y: 0, fade: fadeStop)
            var shadow = l
            shadow.addFilter(.blur(radius: 9 / 2))
            shadow.stroke(Path(roundedRect: bounds, cornerRadius: radius, style: .circular),
                          with: .color(.white.opacity(p.innerShadowAlpha)), lineWidth: 2)
            var mask = l
            mask.blendMode = .destinationIn
            mask.drawLayer { m in
                // Within 28 px of any edge (the two corner fades, added) ...
                let edgeV = min(0.5, 28 / H), edgeH = min(0.5, 28 / W)
                m.fill(Path(bounds), with: .linearGradient(
                    Gradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: edgeV),
                                     .init(color: .clear, location: 1 - edgeV), .init(color: .white, location: 1)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))
                m.fill(Path(bounds), with: .linearGradient(
                    Gradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: edgeH),
                                     .init(color: .clear, location: 1 - edgeH), .init(color: .white, location: 1)]),
                    startPoint: .zero, endPoint: CGPoint(x: W, y: 0)))
                // ... intersected with the range ellipse.
                var e = m
                e.blendMode = .destinationIn
                drawEdgeMask(e, width: 170, height: 64, mid: 0.45, tail: 0.3)
            }
        }

        // Stroke (z 2): the colours in the 1 px edge ring, with the hot core.
        var stroke = ctx
        stroke.opacity = layerOpacity(p.strokeOpacity)
        stroke.drawLayer { l in
            var ring = Path(roundedRect: bounds, cornerRadius: radius, style: .circular)
            ring.addPath(Path(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                              cornerRadius: max(0, radius - 1), style: .circular))
            l.clip(to: ring, style: FillStyle(eoFill: true))
            drawLobes(l, alpha: 1, sw: p.glowWidth, sh: p.glowHeight, y: 2, fade: fadeStop)
            let core = 30 * p.coreSize
            fillEllipse(l, center: CGPoint(x: beamX, y: H + 2 + f.cy), rx: core * f.w, ry: core * f.h, stops: [
                .init(color: .white.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.14), location: 0.3),
                .init(color: .white.opacity(0), location: 0.65),
            ])
            var mask = l
            mask.blendMode = .destinationIn
            drawEdgeMask(mask, width: 170, height: 64, mid: 0.45)
        }

        // Bloom (z 3): the blurred halo, tallest of the three.
        var bloom = ctx
        bloom.opacity = layerOpacity(p.bloomOpacity)
        bloom.drawLayer { l in
            l.drawLayer { b in
                b.addFilter(.blur(radius: max(0.5, 10 * p.glowSize)))
                drawLobes(b, alpha: 0.9, sw: p.glowWidth * 1.15, sh: p.glowHeight * 1.5, y: 0,
                          fade: min(0.95, fadeStop + 0.02))
            }
            var mask = l
            mask.blendMode = .destinationIn
            drawEdgeMask(mask, width: 200, height: 130, mid: 0.35)
        }

        // Band (z 4): the organic bell on the glow's ceiling.
        var band = ctx
        band.opacity = f.opacity * strength
        drawBand(band)
    }

    // MARK: Layers

    private func drawLobes(_ ctx: GraphicsContext, alpha: Double, sw: Double, sh: Double, y: Double, fade: Double) {
        // CSS paints the first background on top: draw the centre lobe last.
        for i in VoiceGlowLobe.all.indices.reversed() {
            let lobe = VoiceGlowLobe.all[i]
            let rx = (lobe.w * sw).rounded() * f.w
            let ry = (lobe.h * sh).rounded() * f.h * f.lobeL[i]
            let x = W / 2 + (f.cx + f.lobeX[i]) * f.w
            let c = colors[i % colors.count]
            fillEllipse(ctx, center: CGPoint(x: x, y: H + y + f.lobeY[i]), rx: rx, ry: ry, stops: [
                .init(color: rgb(c, alpha), location: 0),
                .init(color: rgb(c, 0), location: fade),
            ])
        }
    }

    /// The ellipse every layer is masked to, growing with the level and
    /// narrowed into a beam while processing.
    private func drawEdgeMask(_ ctx: GraphicsContext, width: Double, height: Double, mid: Double, tail: Double = 0) {
        var stops: [Gradient.Stop] = [.init(color: .white, location: 0),
                                      .init(color: .white.opacity(0.5), location: mid)]
        if tail > 0 { stops.append(.init(color: .white.opacity(tail), location: 0.85)) }
        stops.append(.init(color: .white.opacity(0), location: 1))
        fillEllipse(ctx, center: CGPoint(x: beamX, y: H + f.cy),
                    rx: width * p.rangeWidth * f.w * f.mw,
                    ry: height * p.rangeHeight * f.h + f.lift,
                    stops: stops, fillBounds: true)
    }

    /// A CSS `radial-gradient(ellipse rx ry at center, stops)`. With
    /// `fillBounds`, the whole bounds are painted (the padding stop included),
    /// as a mask needs; otherwise only the ellipse's box.
    private func fillEllipse(_ ctx: GraphicsContext, center: CGPoint, rx: Double, ry: Double,
                             stops: [Gradient.Stop], fillBounds: Bool = false) {
        guard rx > 0.01, ry > 0.01 else {
            // A collapsed mask ellipse masks everything out.
            if fillBounds { ctx.fill(Path(bounds), with: .color(.clear)) }
            return
        }
        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        c.scaleBy(x: rx, y: ry)
        let area = fillBounds
            ? CGRect(x: (bounds.minX - center.x) / rx, y: (bounds.minY - center.y) / ry,
                     width: bounds.width / rx, height: bounds.height / ry)
            : CGRect(x: -1, y: -1, width: 2, height: 2)
        c.fill(Path(area), with: .radialGradient(Gradient(stops: stops), center: .zero,
                                                 startRadius: 0, endRadius: 1))
    }

    /// The band line's points (voiceDriver.ts `bandPoints`).
    private func bandPoints() -> [CGPoint] {
        let ceilingHalfWidth = 170.0, ceilingHeight = 64.0, samples = 56
        let centre = W / 2 + f.cx * f.w
        let half = ceilingHalfWidth * p.rangeWidth * f.w * f.mw
        let apex = min(H * 0.82, (ceilingHeight * p.rangeHeight * f.h + f.lift) * p.bandPosition)
        let base = H - p.bandOffset
        let tailT = min(1, f.morph * 4)
        let tail = p.bandTail * (1 - smoothstep(tailT))
        let withTail = tail > 0.001
        let over = withTail ? p.bandTailOverflow : 0
        let x0 = withTail ? -over : centre - half
        let x1 = withTail ? W + over : centre + half
        return (0...samples).map { i in
            let x = x0 + (x1 - x0) * Double(i) / Double(samples)
            let t = max(-1, min(1, (x - centre) / max(1, half)))
            let edge = (x < centre ? centre : W - centre) + over
            let y = bell(t, p: max(0.3, p.bandCurve), sigma: max(0.05, p.bandSpread), skew: p.bandSkew)
                + tailLift(abs(x - centre), edge: edge, lift: tail, position: p.bandTailPosition, curve: p.bandTailCurve)
            let arc = f.morph > 0 ? cornerLift(x, W, radius) * f.morph : 0
            return CGPoint(x: x, y: base - apex * y - arc)
        }
    }

    /// The band: a core light with a red fringe above and a blue one below,
    /// split further and thickened by the voice (voiceDriver.ts `drawBand`).
    private func drawBand(_ ctx: GraphicsContext) {
        let alpha = min(1, 0.6 * p.bandStrength * f.bendA)
        guard alpha >= 0.005, p.bandWidth > 0 else { return }
        let pts = bandPoints()
        guard let first = pts.first, let last = pts.last else { return }

        let bw = p.bandWidth * (1 + 0.35 * f.level)
        let split = p.bandAberration * (0.35 + 0.65 * f.level)
        let dy = 4 + 12 * split
        let dx = 4 * split
        let base = 0.42 * alpha
        let thickness = 14 * bw
        let blur = 3.5 * p.bandWidth / 2
        let endFade = p.bandTail > 0 ? 0.015 : 0.18
        let filt = { (c: SIMD3<Double>) in cssFilter(c, hue: f.hue, brightness: p.brightness, saturation: p.saturation) }

        var line = Path()
        line.addLines(pts)
        func endsFaded(_ c: SIMD3<Double>, _ a: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(stops: [
                .init(color: rgb(c, 0), location: 0), .init(color: rgb(c, a), location: endFade),
                .init(color: rgb(c, a), location: 1 - endFade), .init(color: rgb(c, 0), location: 1),
            ]), startPoint: CGPoint(x: first.x, y: 0), endPoint: CGPoint(x: last.x, y: 0))
        }
        func style(_ width: Double) -> StrokeStyle {
            StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }

        // Halo: wide and hazy.
        var halo = ctx
        halo.addFilter(.blur(radius: blur * 3))
        halo.stroke(line, with: endsFaded(filt(p.bandCore), base * 0.3), style: style(thickness * 2.2))

        // Ridges: stacked strokes of shrinking width, a linear ramp across
        // the band's thickness.
        let ramp: [(Double, Double)] = [(1, 0.16), (0.72, 0.2), (0.46, 0.26), (0.22, 0.34)]
        let ridges: [(SIMD3<Double>, Double, Double, Double)] = [
            (p.bandAbove, 1, dx, -dy),
            (p.bandMid, 0.55, dx * 0.35, -dy * 0.35),
            (p.bandBelow, 1, -dx, dy),
            (p.bandCore, 0.9, 0, 0),
        ]
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: blur))
            for (colour, a, ox, oy) in ridges {
                let c = filt(colour)
                let shifted = line.applying(CGAffineTransform(translationX: ox, y: oy))
                for (widthMul, alphaMul) in ramp {
                    l.stroke(shifted, with: endsFaded(c, base * a * alphaMul), style: style(max(0.6, thickness * widthMul)))
                }
            }
        }
    }
}
