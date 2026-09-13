// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutField
import Metal
import QuartzCore

/// The alignment stage's two lights, drawn as the emitter field's SETTLED
/// state (`dev/notes/settled-emitter-state.md`, audiout-shared ≥ 0.13.0):
/// each light is one fully-emitted source whose rings roll over themselves in
/// place while a compression lobe orbits it — nothing travels outward, so a
/// light can sit on the wire without reading as a wavefront leaving it.
///
/// A `CAMetalLayer`, not an `MTKView`: the stage is one layer tree that a
/// camera transform pushes in and out of, and a sublayer rides that transform
/// and the field's clip for free where a subview would sit outside both. The
/// stage owns the clock (its display link) and hands every frame the lights'
/// live geometry — read off the halo layers' PRESENTATION values, so every
/// authored transition, detent and breath the stage already scripts on those
/// layers drives this field without a second choreography.
///
/// The shader is GENERATED from `AudioutField.defaults` + `.settled`: every
/// shared number is interpolated, never retyped, and `SettledLightLayerTests`
/// fails the moment the generated source stops carrying what the JSON says.
/// The per-surface choices — two sources, each sized to its halo, a `reach`
/// mask at the halo's edge, a ramp built from the light's own token colour —
/// are the sanctioned ones; no shared knob deviates.
///
/// `make()` returns `nil` headless or without a GPU, and the stage then keeps
/// its bitmap halo: a snapshot never depends on a per-frame clock.
final class SettledLightLayer: CAMetalLayer {

    /// One light, in the field layer's own coordinates (points).
    struct Light {
        var centre: CGPoint
        /// Half the halo box's width — the field's unit radius.
        var radius: CGFloat
        var opacity: Float
        /// The light's colour, linear-ish sRGB components.
        var color: SIMD3<Float>
    }

    /// The site composes its stills at t = 40 s and starts its live clock
    /// there (`EmitterFieldView` does the same), so frame one is a developed
    /// field rather than one snapping into being.
    static let timeOrigin: CFTimeInterval = 40
    /// An occlusion or a stalled run loop must not teleport the field.
    private static let maxFrameStep: CFTimeInterval = 0.1
    /// Where the containment mask fades a source to nothing, in units of the
    /// light's radius: the halo box's own edge, so the field occupies exactly
    /// the footprint the bitmap halo did. PER-SURFACE.
    static let reach: Double = 1.0

    private let pipeline: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue
    /// The field's own clock, accumulated frame to frame.
    private var fieldTime: CFTimeInterval = SettledLightLayer.timeOrigin
    private var lastFrameTime: CFTimeInterval?

    /// The GPU-backed layer, or `nil` headless / without Metal — the stage
    /// falls back to its bitmap halo either way.
    static func make() -> SettledLightLayer? {
        guard !HeadlessRuntime.isActive,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              // SwiftPM does not compile `.metal` sources, so the shader is a
              // string compiled at runtime — the sanctioned path here.
              let library = try? device.makeLibrary(source: shaderSource,
                                                    options: MTLCompileOptions()),
              let vertex = library.makeFunction(name: "settled_light_vertex"),
              let fragment = library.makeFunction(name: "settled_light_fragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }
        return SettledLightLayer(device: device, queue: queue, pipeline: pipeline)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.commandQueue = queue
        self.pipeline = pipeline
        super.init()
        self.device = device
        pixelFormat = .bgra8Unorm
        framebufferOnly = true
        // The plate shows through between crests: the shader writes
        // premultiplied colour over a transparent clear.
        isOpaque = false
        anchorPoint = .zero
    }

    override init(layer: Any) {
        // Presentation copies never render; they only carry geometry.
        let source = layer as! SettledLightLayer
        commandQueue = source.commandQueue
        pipeline = source.pipeline
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Size the drawable to the layer at the window's scale. Off the animated
    /// path, like the stage's own container layers.
    func fit(to size: CGSize, scale: CGFloat) {
        contentsScale = scale
        bounds = CGRect(origin: .zero, size: size)
        position = .zero
        drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// One frame. `now` is the display link's timestamp — `nil` draws a still
    /// at the clock's current value without advancing it (Reduce Motion, a
    /// resize while paused).
    func render(lights: [Light], now: CFTimeInterval?) {
        if let now {
            if let last = lastFrameTime {
                fieldTime += Swift.min(now - last, Self.maxFrameStep)
            }
            lastFrameTime = now
        }
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = makeUniforms(lights: lights)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// A resume after a pause must not bill the field for the gap.
    func resetClock() { lastFrameTime = nil }

    // MARK: Uniforms

    /// Field order is the layout contract with the shader's `Uniforms` —
    /// same order, same bytes. Two lights, fixed: the stage has exactly two.
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var scale: Float
        var centre0: SIMD2<Float>
        var centre1: SIMD2<Float>
        var radius: SIMD2<Float>
        var opacity: SIMD2<Float>
        var color0: SIMD3<Float>
        var color1: SIMD3<Float>
    }

    private func makeUniforms(lights: [Light]) -> Uniforms {
        let scale = Float(contentsScale)
        func px(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float(p.x) * scale, Float(p.y) * scale)
        }
        let a = lights.count > 0 ? lights[0] : Light(centre: .zero, radius: 1, opacity: 0, color: .zero)
        let b = lights.count > 1 ? lights[1] : Light(centre: .zero, radius: 1, opacity: 0, color: .zero)
        return Uniforms(
            resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            // `timeScale` multiplies the clock ONCE, here — never folded into
            // the individual rates (the field skill's rule for this state).
            time: Float(fieldTime * AudioutField.settled.timeScale),
            scale: scale,
            centre0: px(a.centre), centre1: px(b.centre),
            radius: SIMD2(Float(max(a.radius, 1)) * scale, Float(max(b.radius, 1)) * scale),
            opacity: SIMD2(a.opacity, b.opacity),
            color0: a.color, color1: b.color)
    }

    // MARK: Shader

    /// MSL wants a decimal point on every float literal, and a shared number
    /// must reach the shader as itself — never rounded to something tidier.
    static func msl(_ value: Double) -> String { String(format: "%.4f", value) }

    /// Metal Shading Language for the settled state, GENERATED from the
    /// shared numbers. Steps 1, 2, 5 and 7 of the hero formula are the
    /// shared defaults; steps 3–4 and the breathing are the `settled` block.
    /// `speedBase`/`speedStep` are retired in this state (no outward phase
    /// term) — see the brief.
    static let shaderSource: String = {
        let d = AudioutField.defaults
        let s = AudioutField.settled
        return """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float scale;
        float2 centre0;
        float2 centre1;
        float2 radius;
        float2 opacity;
        float3 color0;
        float3 color1;
    };

    vertex float4 settled_light_vertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        return float4(corners[vid], 0.0, 1.0);
    }

    static float sstep(float e0, float e1, float x) {
        float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    }

    /// One settled source at `c` with unit radius `radius`, in pixels.
    static float source(float2 frag, float2 c, float radius, float t, float k) {
        float seed = k * 6.13 + 1.7;
        // Step 1 — orbit, at the settled (smaller) radius.
        float2 uv = (frag - c) / radius;
        float2 centre = \(msl(s.orbit)) * float2(sin(t * 0.030 + seed), cos(t * 0.026 + seed * 1.7));
        float2 dv = uv - centre;
        // Step 2 — squash: the wavefronts read as slight ovals.
        float r = length(dv * float2(1.0, \(msl(d.squash))));
        float th = atan2(dv.y, dv.x);
        // Lobe and curl both fade to zero inside `taper`, so the innermost
        // ring can never fold into itself (load-bearing — see the brief).
        float taperF = smoothstep(0.0, \(msl(s.taper)), r);
        // Steps 3–4, settled: an oval compression lobe orbits the source …
        float roll = (\(msl(s.rollAmp)) * cos(th - t * \(msl(s.rollRate)) - seed)
                   + \(msl(s.rollAmp)) * 0.35 * cos(2.0 * th + t * \(msl(s.rollRate)) * 0.61 + seed * 1.3))
                   * taperF;
        float dens = \(msl(d.densBase)) + \(msl(d.densStep)) * k;
        float ph = r * dens + seed - roll;      // no -t*speed: nothing travels outward
        // … and each crest rolls over itself in place (never around the rim).
        float ph2 = ph + \(msl(s.curlAmp)) * sin(ph - t * \(msl(s.curlRate))) * taperF;
        float rings = pow(0.5 + 0.5 * sin(ph2), \(msl(d.sharp)));
        // Step 5 — falloff.
        float fall = exp(-r * \(msl(d.fade)));
        // Step 6 — the settled breath: brightness holds nearly steady.
        float swell = \(msl(s.breatheFloor)) + \(msl(s.breatheDepth))
                    * (0.5 + 0.5 * sin(t * (\(msl(d.breatheRate)) + \(msl(d.breatheStep)) * k) + seed * 2.3));
        // PER-SURFACE: contain the source at its halo's edge.
        float cap = 1.0 - sstep(0.55 * \(msl(reach)), \(msl(reach)), r);
        return rings * fall * swell * cap * \(msl(d.gain));
    }

    fragment float4 settled_light_fragment(float4 position [[position]],
                                           constant Uniforms &u [[buffer(0)]]) {
        // Metal's fragment y runs down; the stage's layers are authored y-up.
        float2 frag = float2(position.x, u.resolution.y - position.y);
        float3 col = float3(0.0);
        float alpha = 0.0;
        float2 centres[2] = { u.centre0, u.centre1 };
        float3 colors[2] = { u.color0, u.color1 };
        for (int k = 0; k < 2; ++k) {
            float light = source(frag, centres[k], u.radius[k], u.time, float(k));
            // The site's tone curve, then the light's own colour at that
            // intensity — the halo's job, now with structure in it.
            float l = pow(1.0 - exp(-light * 1.2), 1.35) * u.opacity[k];
            col += colors[k] * l;
            alpha += l;
        }
        alpha = min(alpha, 1.0);
        // Dither so the shallow washes do not band; premultiplied out.
        float grain = (hash(frag) - 0.5) * 0.012;
        return float4(min(col, float3(alpha)) + grain * alpha, alpha);
    }
    """
    }()
}
