// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI
import MetalKit

/// The animated ground of the first-open licence window: three "emitters"
/// radiating concentric rings across a warm field, drawn by a Metal fragment
/// shader.
///
/// A native port of the marketing site's WebGL hero, remapped from the site's
/// green to the app's warm gold ramp (`canvas` → `ember` → `accent` → a lifted
/// peak). The field's MECHANISM in ``shaderSource`` — orbit drift, squash,
/// ring shape (`pow(sin, 4)`), falloff, breathing, tone-map exponents and mix
/// domains — mirrors the website's `fields/emitters.js` DEFAULTS, and those
/// parts must move together with the site or the brand's one moving image
/// silently forks. Four values are DELIBERATE stage tunings for this window
/// (a ~440 pt stage vs a viewport hero) and are marked inline: the emitter
/// centres (triangulated around the content column), ring density ×1.7 and
/// speed ×1.4 (the site's wavelength reads as blobs at this size), and a
/// gentler paper lift.
///
/// It is ORNAMENT: it carries no state, and under Reduce Motion it holds a
/// single still frame rather than looping. Headless runs never create a Metal
/// device at all, so snapshots stay deterministic. Every failure path — no
/// device, a library that will not compile, a pipeline that will not build —
/// lands on the flat `canvas` ground this view stamps on its own layer, which
/// is also what covers the window before the first frame arrives.
@MainActor
final class EmitterFieldView: NSView {

    /// Base energy of the field. The surge envelope adds on top of it.
    private static let baseGain: Float = 0.65
    /// The site composes its stills at t = 40 s and starts its live clock
    /// there, so frame one is a developed field rather than three points
    /// snapping outward from nothing. Same here.
    private static let timeOrigin: CFTimeInterval = 40

    private var mtkView: MTKView?
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    /// `start()`ed and not `stop()`ped — the user-facing intent, separate from
    /// whether the loop happens to be paused for occlusion or Reduce Motion.
    private var wantsAnimation = false
    private var startAnchor: CFTimeInterval = CACurrentMediaTime()
    private var surgeAnchor: CFTimeInterval?
    private var occlusionObserver: NSObjectProtocol?

    /// `nil` = the live Reduce Motion setting.
    var test_reduceMotionOverride: Bool?

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True only while the draw loop is actually running.
    var test_isAnimating: Bool {
        guard let mtkView else { return false }
        return wantsAnimation && !mtkView.isPaused
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stampGround()
        buildMetal()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentStyleChanged),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    // MARK: Lifecycle

    /// Begin animating — or, under Reduce Motion, draw the one still frame.
    func start() {
        wantsAnimation = true
        startAnchor = CACurrentMediaTime()
        reconcileMotion()
    }

    /// Stop rendering entirely. Nothing restarts the loop until `start()`.
    func stop() {
        wantsAnimation = false
        mtkView?.isPaused = true
    }

    /// One-shot swell of the field's energy — the success moment. No-op while
    /// stopped or under Reduce Motion, where there is no motion to swell.
    func surge() {
        guard wantsAnimation, !reduceMotion, mtkView != nil else { return }
        surgeAnchor = CACurrentMediaTime()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileMotion() }
                }
        }
        reconcileMotion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stampGround()
        redrawStillIfPaused()
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        // A mid-session Reduce Motion toggle arrives through this notification
        // and nowhere else (SharedUI AGENTS.md).
        reconcileMotion()
    }

    @objc private func accentStyleChanged() {
        // Colours re-resolve on the next draw; a paused field needs that draw
        // asking for.
        redrawStillIfPaused()
    }

    /// The single place that decides loop / still / nothing.
    private func reconcileMotion() {
        guard let mtkView else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        let shouldLoop = wantsAnimation && !reduceMotion && visible
        mtkView.isPaused = !shouldLoop
        if !shouldLoop {
            surgeAnchor = nil
            if wantsAnimation { mtkView.needsDisplay = true }
        }
    }

    private func redrawStillIfPaused() {
        guard let mtkView, mtkView.isPaused else { return }
        mtkView.needsDisplay = true
    }

    // MARK: Ground

    /// The flat warm ground. It is the whole picture when Metal is unavailable
    /// or headless, and behind the Metal view it is what stops a black flash
    /// before the first frame.
    private func stampGround() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.canvas.cgColor
        }
    }

    // MARK: Metal

    private func buildMetal() {
        // A headless run gets the flat ground and nothing else: no device, no
        // drawable, no per-frame clock for a snapshot to disagree about.
        guard !HeadlessRuntime.isActive,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              // SwiftPM does not compile `.metal` sources, so the shader is a
              // string compiled at runtime — the sanctioned path here.
              let library = try? device.makeLibrary(source: Self.shaderSource,
                                                    options: MTLCompileOptions()),
              let vertexFunction = library.makeFunction(name: "emitter_field_vertex"),
              let fragmentFunction = library.makeFunction(name: "emitter_field_fragment")
        else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return }

        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        // The field breathes over tens of seconds; 30 fps is deliberate
        // battery kindness, not a corner cut.
        view.preferredFramesPerSecond = 30
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        addSubview(view)

        self.commandQueue = queue
        self.pipeline = pipeline
        self.mtkView = view
    }

    /// One frame's worth of CPU-side state, laid out to match `Uniforms` in the
    /// shader (`float3` is 16-byte aligned on both sides).
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var lightMode: Float
        var gain: Float
        var bg: SIMD3<Float>
        var lo: SIMD3<Float>
        var mid: SIMD3<Float>
        var peak: SIMD3<Float>
    }

    private func makeUniforms(drawableSize: CGSize) -> Uniforms {
        let isLight = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        var bg = SIMD3<Float>(repeating: 0)
        var lo = SIMD3<Float>(repeating: 0)
        var mid = SIMD3<Float>(repeating: 0)
        var peak = SIMD3<Float>(repeating: 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // `Tokens.Color.accent` is the SEMANTIC alias (`controlAccentColor`,
            // i.e. system blue by default) — the field's hue is the authored
            // `gold`, which also follows the accent dial.
            let accent = Tokens.Color.gold
            bg = Self.components(of: Tokens.Color.canvas)
            // The site's light ramp inverts — a PALE wash deepening into ink
            // on paper, instead of blooming white out of the dark. So light
            // mode's low stop is a near-paper gold and its peak is the darkest
            // stop; dark mode runs ember → gold → lifted cream.
            lo = Self.components(of: isLight
                ? accent.blended(withFraction: 0.6, of: .white) ?? accent
                : Tokens.Color.ember)
            mid = Self.components(of: accent)
            peak = Self.components(of: isLight
                ? accent.blended(withFraction: 0.55, of: .black) ?? accent
                : accent.blended(withFraction: 0.7, of: .white) ?? accent)
        }

        let now = CACurrentMediaTime()
        let paused = mtkView?.isPaused ?? true
        // A still is composed at the origin; the live clock counts from it.
        let time = paused ? Self.timeOrigin : Self.timeOrigin + (now - startAnchor)

        return Uniforms(
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            time: Float(time),
            lightMode: isLight ? 1 : 0,
            gain: Self.baseGain + 0.55 * surgeEnvelope(at: now),
            bg: bg, lo: lo, mid: mid, peak: peak)
    }

    /// Fast attack, ~1.4 s decay — the site's `beat` pulse shape, slowed to
    /// this field's pace.
    private func surgeEnvelope(at now: CFTimeInterval) -> Float {
        guard let surgeAnchor else { return 0 }
        let x = Float(now - surgeAnchor)
        guard x >= 0 else { return 0 }
        let attack = min(max(x / 0.15, 0), 1)
        return attack * attack * (3 - 2 * attack) * exp(-2.6 * x)
    }

    private static func components(of color: NSColor) -> SIMD3<Float> {
        guard let srgb = color.usingColorSpace(.sRGB) else { return SIMD3<Float>(repeating: 0) }
        return SIMD3<Float>(Float(srgb.redComponent),
                            Float(srgb.greenComponent),
                            Float(srgb.blueComponent))
    }

    // MARK: Shader

    /// Metal Shading Language source for the field. See the type's doc comment:
    /// these constants are the website's shipped hero and are not free to drift.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float lightMode;
        float gain;
        float3 bg;
        float3 lo;
        float3 mid;
        float3 peak;
    };

    vertex float4 emitter_field_vertex(uint vid [[vertex_id]]) {
        // Fullscreen triangle — no vertex buffers, no geometry to keep in sync.
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        return float4(corners[vid], 0.0, 1.0);
    }

    // MSL leaves `smoothstep` undefined when edge0 >= edge1, and two of the
    // masks below run their edges backwards (as the GLSL original does), so
    // the interpolation is spelled out rather than left to the builtin.
    static float sstep(float e0, float e1, float x) {
        float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    fragment float4 emitter_field_fragment(float4 position [[position]],
                                           constant Uniforms &u [[buffer(0)]]) {
        // Metal's fragment y runs down; the composition (emitter 3 sits in the
        // UPPER half) is authored y-up.
        float2 fragCoord = float2(position.x, u.resolution.y - position.y);
        float2 uv = (fragCoord - 0.5 * u.resolution) / u.resolution.y;
        float t = u.time;

        // STAGE TUNING: the site's centres sit for a viewport-wide hero; these
        // triangulate around this window's centred content column instead, so
        // no corner of the stage goes dead.
        float2 centres[3] = { float2(-0.62, 0.30), float2(0.72, -0.34), float2(0.08, 0.52) };
        float light = 0.0;
        for (int k = 0; k < 3; ++k) {
            float f = float(k);
            float seed = f * 6.13 + 1.7;
            float2 c = centres[k] + 0.1 * float2(sin(t * 0.030 + seed),
                                                 cos(t * 0.026 + seed * 1.7));
            float r = length((uv - c) * float2(1.0, 1.12));
            // STAGE TUNING: density ×1.7 / speed ×1.4 on the site's values —
            // at ~440 pt the site's ring wavelength reads as blobs, not waves.
            float speed = (1.11 + 0.20 * f) * 1.4;
            float dens = (17.0 + 3.0 * f) * 1.7;
            float rings = pow(0.5 + 0.5 * sin(r * dens - t * speed + seed), 4.0);
            float fall = exp(-r * 1.5);
            float swell = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * (0.10 + 0.028 * f) + seed * 2.3));
            light += rings * fall * swell * u.gain;
        }
        // Paper lift: the light ramp needs more energy to read on white.
        // STAGE TUNING: the site lifts ×1.94; this smaller, busier stage
        // overcooks there.
        light *= mix(1.0, 1.55, u.lightMode);

        // Calm zones top and bottom, then a hollow through the middle so the
        // window's text sits on quiet ground.
        light *= sstep(-0.62, -0.38, uv.y) * sstep(0.72, 0.35, uv.y);
        light *= 1.0 - 0.55 * sstep(0.72, 0.12, length(uv * float2(0.62, 1.45)));

        float l = pow(1.0 - exp(-light * 1.2), 1.35);
        float3 col = mix(u.bg, u.lo, sstep(0.0, 0.45, l));
        col = mix(col, u.mid, sstep(0.4, 0.8, l));
        col = mix(col, u.peak, sstep(0.78, 1.0, l));
        // Dither: without it the wide, shallow washes band on 8-bit displays.
        col += (hash(fragCoord) - 0.5) * 0.012;
        return float4(col, 1.0);
    }
    """
}

extension EmitterFieldView: MTKViewDelegate {

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { self.redrawStillIfPaused() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let pipeline, let commandQueue,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = commandQueue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            var uniforms = makeUniforms(drawableSize: view.drawableSize)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
