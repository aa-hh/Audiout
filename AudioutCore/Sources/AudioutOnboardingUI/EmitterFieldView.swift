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
/// It is ORNAMENT: it decides nothing and carries no state of its own beyond
/// the ``Scene`` the gate hands it, and under Reduce Motion it holds a single
/// still frame rather than looping. Headless runs never create a Metal
/// device at all, so snapshots stay deterministic. Every failure path — no
/// device, a library that will not compile, a pipeline that will not build —
/// lands on the flat `canvas` ground this view stamps on its own layer, which
/// is also what covers the window before the first frame arrives.
///
/// The SCENE system is what lets the gate speak through the ground while the
/// foreground stays still: ``setScene(_:)`` names a state (steady, thinking,
/// quiet, waiting, farewell) and every scene is nothing but a set of shader
/// UNIFORM targets — energy, per-emitter gain, dim, breathing amplitude,
/// hollow radius, clock rate — eased on the CPU toward their new values each
/// frame. No `CAAnimation` is involved, so there is one clock and one place a
/// frame's picture comes from. Because the choreography is values rather than
/// motion, Reduce Motion and a paused (occluded/stopped) field degrade to
/// RECOMPOSED STILLS: the values jump and one frame is redrawn, so each scene
/// still reads as a different picture rather than as nothing happening.
@MainActor
final class EmitterFieldView: NSView {

    /// What the field is currently saying. Every case is a set of uniform
    /// targets in ``targets(for:)`` — nothing here reaches the foreground.
    enum Scene: Equatable {
        /// Base gain, breathing on, no dim, normal time.
        case idle
        /// Breathing amplitude eased to 0 — the field steadies.
        case typing
        /// Steady, with all three emitters lifted and held: a nod.
        case armed
        /// The three emitters hand the lead around, one lap ≈ 0.9 s.
        case checking
        /// Dimmed with the rings frozen mid-flight — the error state.
        case quiet
        /// Dimmed further and slowed — the buy-and-return waiting room.
        case waiting
        /// The hollow expands past the frame: the handoff out of the gate.
        case farewell
    }

    /// Base energy of the field. The surge envelope adds on top of it.
    private static let baseGain: Float = 0.65
    /// The site composes its stills at t = 40 s and starts its live clock
    /// there, so frame one is a developed field rather than three points
    /// snapping outward from nothing. Same here.
    private static let timeOrigin: CFTimeInterval = 40
    /// Scene crossfade. `farewell` is the one exception — it is a departure,
    /// not a change of mood, so it takes about twice as long.
    private static let sceneTransition: CFTimeInterval = 0.45
    private static let farewellTransition: CFTimeInterval = 0.9
    /// Past the frame's far corner (the widest `hollowUV` this window can
    /// produce is ≈ 0.85, against an inner radius of 0.12 × 6 = 0.72).
    private static let farewellHollowRadius: Float = 6
    /// `armed` lifts every emitter by this much and holds it.
    private static let armedLift: Float = 1.10
    /// `checking`'s lead: one lap of the three emitters, and how far the
    /// leading one rides above the other two.
    private static let checkingLap: CFTimeInterval = 0.9
    private static let checkingLeadDepth: Float = 0.45
    /// An occlusion or a stalled run loop must not teleport the field: a gap
    /// longer than this contributes one frame's worth of time and no more.
    private static let maxFrameStep: CFTimeInterval = 0.1

    private var mtkView: MTKView?
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    /// `start()`ed and not `stop()`ped — the user-facing intent, separate from
    /// whether the loop happens to be paused for occlusion or Reduce Motion.
    private var wantsAnimation = false
    private var surgeAnchor: CFTimeInterval?
    private var surgeIntensity: Float = 1
    private var occlusionObserver: NSObjectProtocol?

    /// The field's own clock, ACCUMULATED rather than read off the wall: two
    /// scenes bend the rate (`quiet` stops it, `waiting` runs it at 0.4×), so
    /// no elapsed-since-anchor expression can describe it any more.
    private var fieldTime: CFTimeInterval = EmitterFieldView.timeOrigin
    /// `nil` = no frame to measure against, so the next one contributes no time
    /// (a fresh start, or a resume after the loop was paused).
    private var lastFrameTime: CFTimeInterval?

    private var scene: Scene = .idle
    private var sceneFrom = EmitterFieldView.targets(for: .idle)
    private var sceneTarget = EmitterFieldView.targets(for: .idle)
    private var sceneCurrent = EmitterFieldView.targets(for: .idle)
    /// 0…1 through the current transition; 1 = settled on `sceneTarget`.
    private var sceneProgress: CFTimeInterval = 1
    private var sceneDuration: CFTimeInterval = EmitterFieldView.sceneTransition

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

    /// The last scene set, whether or not its transition has finished.
    var test_scene: Scene { scene }

    /// No loop to ease along: the scene has to arrive as a recomposed still.
    private var rendersStills: Bool {
        reduceMotion || (mtkView?.isPaused ?? true)
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
        fieldTime = Self.timeOrigin
        lastFrameTime = nil
        reconcileMotion()
    }

    /// Stop rendering entirely. Nothing restarts the loop until `start()`.
    func stop() {
        wantsAnimation = false
        mtkView?.isPaused = true
    }

    /// One-shot swell of the field's energy — the success moment, at
    /// `intensity` 1; a quieter gesture (0.5) is what the states that cannot
    /// celebrate get. No-op while stopped or under Reduce Motion, where there
    /// is no motion to swell.
    func surge(intensity: Float = 1.0) {
        guard wantsAnimation, !reduceMotion, mtkView != nil else { return }
        surgeIntensity = intensity
        surgeAnchor = CACurrentMediaTime()
    }

    /// The full-strength surge, spelled for callers that pass nothing.
    func surge() { surge(intensity: 1) }

    /// Move the ground to `scene`. Idempotent, and under Reduce Motion or while
    /// paused the values JUMP and one frame is redrawn — a recomposed still,
    /// not a frozen transition.
    func setScene(_ scene: Scene) {
        guard scene != self.scene else { return }
        self.scene = scene
        sceneTarget = Self.targets(for: scene)
        sceneDuration = scene == .farewell ? Self.farewellTransition : Self.sceneTransition
        if rendersStills {
            settleScene()
            redrawStillIfPaused()
        } else {
            sceneFrom = sceneCurrent
            sceneProgress = 0
        }
    }

    /// Land on the target with no transition left to run.
    private func settleScene() {
        sceneFrom = sceneTarget
        sceneCurrent = sceneTarget
        sceneProgress = 1
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
        // Either direction, the next frame has no predecessor to measure a
        // delta against: a resume must not bill the field for the pause.
        lastFrameTime = nil
        if !shouldLoop {
            surgeAnchor = nil
            // A still has to read as a settled scene, never as a transition
            // caught halfway.
            settleScene()
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

    // MARK: Scenes

    /// Where one scene parks every animated value. Nothing here is a duration
    /// or a curve: a scene IS a set of targets, and the same easing carries all
    /// of them.
    private struct SceneTargets {
        var gain: Float
        var emitterGain: SIMD3<Float>
        var dim: Float
        var breath: Float
        var hollowRadius: Float
        var timeScale: Float
        /// How much of `checking`'s rotating lead is mixed in. NOT a uniform —
        /// it eases with the rest so entering and leaving `checking` fades the
        /// rotation instead of snapping it on the beat the check resolves.
        var lead: Float

        static func mix(_ a: SceneTargets, _ b: SceneTargets, _ t: Float) -> SceneTargets {
            SceneTargets(
                gain: a.gain + (b.gain - a.gain) * t,
                emitterGain: a.emitterGain + (b.emitterGain - a.emitterGain) * t,
                dim: a.dim + (b.dim - a.dim) * t,
                breath: a.breath + (b.breath - a.breath) * t,
                hollowRadius: a.hollowRadius + (b.hollowRadius - a.hollowRadius) * t,
                timeScale: a.timeScale + (b.timeScale - a.timeScale) * t,
                lead: a.lead + (b.lead - a.lead) * t)
        }
    }

    /// `idle` is the field as shipped — every other scene is a departure from
    /// it, written as the values it changes and nothing else.
    private static func targets(for scene: Scene) -> SceneTargets {
        var t = SceneTargets(gain: baseGain, emitterGain: SIMD3<Float>(repeating: 1),
                             dim: 1, breath: 1, hollowRadius: 1, timeScale: 1, lead: 0)
        switch scene {
        case .idle: break
        case .typing: t.breath = 0
        case .armed: t.breath = 0; t.emitterGain = SIMD3<Float>(repeating: armedLift)
        case .checking: t.lead = 1
        case .quiet: t.dim = 0.5; t.timeScale = 0
        case .waiting: t.dim = 0.35; t.timeScale = 0.4
        case .farewell: t.hollowRadius = farewellHollowRadius
        }
        return t
    }

    private static func easeOutCubic(_ t: Float) -> Float {
        let inv = 1 - min(max(t, 0), 1)
        return 1 - inv * inv * inv
    }

    /// One frame of CPU-side clockwork: the field's own time, then the scene
    /// interpolation. Both are billed against the wall clock, but only the
    /// FIELD's time is scaled — a transition is chrome and runs at real speed
    /// even while the rings are stopped.
    private func advance(to now: CFTimeInterval) {
        let elapsed = min(max(now - (lastFrameTime ?? now), 0), Self.maxFrameStep)
        lastFrameTime = now
        guard !(mtkView?.isPaused ?? true) else { return }
        if sceneProgress < 1 {
            sceneProgress = min(1, sceneProgress + elapsed / sceneDuration)
            sceneCurrent = SceneTargets.mix(sceneFrom, sceneTarget,
                                            Self.easeOutCubic(Float(sceneProgress)))
        }
        fieldTime += elapsed * CFTimeInterval(sceneCurrent.timeScale)
    }

    /// `checking`'s lead, laid over whatever the scene interpolation produced:
    /// a cosine one third of a lap apart per emitter, so the brightest one
    /// travels around the three without any of them going dark.
    private func emitterGain() -> SIMD3<Float> {
        var gains = sceneCurrent.emitterGain
        guard sceneCurrent.lead > 0 else { return gains }
        for k in 0..<3 {
            let phase = 2 * Float.pi * Float(fieldTime / Self.checkingLap - Double(k) / 3)
            gains[k] *= 1 + sceneCurrent.lead * Self.checkingLeadDepth * cos(phase)
        }
        return gains
    }

    /// One frame's worth of CPU-side state, laid out to match `Uniforms` in the
    /// shader. LAYOUT PARITY: MSL and Swift's SIMD types agree field for field —
    /// `float`/`Float` align 4, `float2`/`SIMD2<Float>` align 8, and
    /// `float3`/`SIMD3<Float>` align 16 and OCCUPY 16 — so declaring the two
    /// structs in the same order is what keeps them the same bytes. The order
    /// below packs the two `float2`s and the six scalars into the first 40
    /// bytes (8 of tail padding to the first 16-byte boundary) and then runs
    /// the five `float3`s: offsets 48, 64, 80, 96, 112, stride 128. Add a field
    /// to one struct and it goes in the same position in the other.
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var hollowCenter: SIMD2<Float>
        var time: Float
        var lightMode: Float
        var gain: Float
        var dim: Float
        var breath: Float
        var hollowRadius: Float
        var emitterGain: SIMD3<Float>
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
        // A still renders at the clock's current reading, which for a field
        // that has never run is the site's t = 40 composition point.
        advance(to: now)

        return Uniforms(
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            // The site's hollow is centred on the frame; the offset exists so a
            // scene can move it, and no scene does today.
            hollowCenter: SIMD2<Float>(0, 0),
            time: Float(fieldTime),
            lightMode: isLight ? 1 : 0,
            gain: sceneCurrent.gain + 0.55 * surgeEnvelope(at: now) * surgeIntensity,
            dim: sceneCurrent.dim,
            breath: sceneCurrent.breath,
            hollowRadius: sceneCurrent.hollowRadius,
            emitterGain: emitterGain(),
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

    // Field order is the layout contract with the Swift `Uniforms` struct —
    // see its doc comment. Same order, same bytes.
    struct Uniforms {
        float2 resolution;
        float2 hollowCenter;
        float time;
        float lightMode;
        float gain;
        float dim;
        float breath;
        float hollowRadius;
        float3 emitterGain;
        float3 bg;
        float3 lo;
        float3 mid;
        float3 peak;
    };

    // Attenuation at the bottom of the hollow. At hollowRadius = 1 the inner
    // edge is 0.12, where sstep returns 1 and the mask is 1 - 0.85 = 0.15 —
    // i.e. the centre keeps 15% of the field's light, the contrast floor the
    // window's text sits on.
    constant float hollowDepth = 0.85;

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
            // `breath` scales only the OSCILLATING half and pays the rest back
            // at its midpoint, so breath = 1 is the site's swell, breath = 0
            // pins it at 0.7 (steady), and the crossfade between them is
            // continuous.
            float wave = 0.5 + 0.5 * sin(t * (0.10 + 0.028 * f) + seed * 2.3);
            float swell = 0.4 + 0.6 * u.breath * wave + 0.6 * (1.0 - u.breath) * 0.5;
            light += rings * fall * swell * u.gain * u.emitterGain[k];
        }
        // Paper lift: the light ramp needs more energy to read on white.
        // STAGE TUNING: the site lifts ×1.94; this smaller, busier stage
        // overcooks there.
        light *= mix(1.0, 1.55, u.lightMode);

        // Calm zones top and bottom, then a hollow through the middle so the
        // window's text sits on quiet ground.
        light *= sstep(-0.62, -0.38, uv.y) * sstep(0.72, 0.35, uv.y);
        // Same ellipse, parameterised: hollowRadius 1 is the shipped picture,
        // and `farewell` grows it until the inner edge swallows the frame.
        float hollow = length((uv - u.hollowCenter) * float2(0.62, 1.45));
        light *= 1.0 - hollowDepth * sstep(0.72 * u.hollowRadius,
                                           0.12 * u.hollowRadius, hollow);

        float l = pow(1.0 - exp(-light * 1.2), 1.35);
        float3 col = mix(u.bg, u.lo, sstep(0.0, 0.45, l));
        col = mix(col, u.mid, sstep(0.4, 0.8, l));
        col = mix(col, u.peak, sstep(0.78, 1.0, l));
        // The dim is a retreat toward the ground, not a fade to black, and it
        // lands before the dither so a dimmed field keeps its grain.
        col = mix(u.bg, col, u.dim);
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
