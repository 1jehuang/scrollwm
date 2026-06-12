import Foundation
import AppKit
import Metal
import QuartzCore
import simd

// MARK: - Shaders

/// Rounded-rect instanced quads. Embedded so SPM needs no resource bundle.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct InstanceData {
    float4 rect;   // x, y, w, h in canvas points (top-left origin)
    float4 color;
};

struct Uniforms {
    float2 viewportOrigin; // canvas point at screen (0,0)
    float2 screenSize;     // points
};

struct VOut {
    float4 position [[position]];
    float4 color;
    float2 local;    // 0..1 inside rect
    float2 sizePts;  // rect size in points
};

vertex VOut vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                  const device InstanceData* instances [[buffer(0)]],
                  constant Uniforms& u [[buffer(1)]]) {
    float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1),
                          float2(1,0), float2(1,1), float2(0,1) };
    InstanceData inst = instances[iid];
    float2 c = corners[vid];
    float2 pts = inst.rect.xy - u.viewportOrigin + c * inst.rect.zw;
    float2 ndc = float2(pts.x / u.screenSize.x * 2.0 - 1.0,
                        1.0 - pts.y / u.screenSize.y * 2.0);
    VOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    out.local = c;
    out.sizePts = inst.rect.zw;
    return out;
}

fragment float4 fmain(VOut in [[stage_in]]) {
    const float radius = 10.0;
    float2 p = in.local * in.sizePts;
    float2 cornerDist = float2(min(p.x, in.sizePts.x - p.x),
                               min(p.y, in.sizePts.y - p.y));
    float alpha = in.color.a;
    if (cornerDist.x < radius && cornerDist.y < radius) {
        float r = length(float2(radius - cornerDist.x, radius - cornerDist.y));
        alpha *= 1.0 - smoothstep(radius - 1.0, radius + 0.5, r);
    }
    return float4(in.color.rgb * alpha, alpha); // premultiplied
}
"""

// MARK: - GPU data layouts (must match MSL structs)

struct InstanceData {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
}

struct Uniforms {
    var viewportOrigin: SIMD2<Float>
    var screenSize: SIMD2<Float>
}

// MARK: - Viewport physics

/// Canvas viewport with inertial panning.
struct ViewportPhysics {
    var origin = SIMD2<Double>(0, 0)
    var velocity = SIMD2<Double>(0, 0) // points/sec

    private var lastSampleTimeNs: UInt64 = 0

    mutating func apply(samples: [ScrollSample], nowNs: UInt64) {
        guard !samples.isEmpty else { return }
        var total = SIMD2<Double>(0, 0)
        for s in samples {
            total.x += s.deltaX
            total.y += s.deltaY
        }
        // Natural scrolling: content follows fingers; viewport moves opposite.
        origin -= total

        // Velocity estimate from this batch.
        let dtNs = nowNs &- (lastSampleTimeNs == 0 ? nowNs : lastSampleTimeNs)
        let dt = max(Double(dtNs) / 1e9, 1.0 / 240.0)
        velocity = -total / dt
        lastSampleTimeNs = nowNs
    }

    /// Inertia when no input is arriving.
    mutating func coast(dt: Double, nowNs: UInt64) {
        let idleNs = nowNs &- lastSampleTimeNs
        guard lastSampleTimeNs != 0, idleNs > 30_000_000 else { return } // 30 ms grace
        let speed = simd_length(velocity)
        guard speed > 5 else { velocity = .zero; return }
        origin += velocity * dt
        velocity *= exp(-dt / 0.55) // friction time constant
    }
}

// MARK: - Fake canvas (Milestone 3 stand-in for real window proxies)

enum FakeCanvas {
    static func makeWindows(screen: CGSize, count: Int = 36) -> [InstanceData] {
        var rng = SystemRandomNumberGenerator()
        var result: [InstanceData] = []
        let canvasW = screen.width * 4
        let canvasH = screen.height * 2
        for i in 0..<count {
            let w = Double.random(in: 320...720, using: &rng)
            let h = Double.random(in: 240...560, using: &rng)
            let x = Double.random(in: -canvasW/2...(canvasW - w), using: &rng)
            let y = Double.random(in: 0...(canvasH - h), using: &rng)
            let hue = Double(i) / Double(count)
            let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 0.92)
            let rgb = color.usingColorSpace(.deviceRGB)!
            result.append(InstanceData(
                rect: SIMD4<Float>(Float(x), Float(y), Float(w), Float(h)),
                color: SIMD4<Float>(Float(rgb.redComponent), Float(rgb.greenComponent),
                                    Float(rgb.blueComponent), Float(rgb.alphaComponent))
            ))
        }
        return result
    }
}

// MARK: - Metrics

final class OverlayMetrics {
    var frameIntervalsMs: [Double] = []
    var inputAgesMs: [Double] = []
    var framesRendered = 0
    var samplesConsumed = 0
    private var lastFrameNs: UInt64 = 0

    func onFrame(nowNs: UInt64, consumed: [ScrollSample]) {
        framesRendered += 1
        if lastFrameNs != 0 {
            frameIntervalsMs.append(Double(nowNs &- lastFrameNs) / 1e6)
        }
        lastFrameNs = nowNs
        samplesConsumed += consumed.count
        for s in consumed where s.eventTimestampNs > 0 && s.eventTimestampNs <= nowNs {
            inputAgesMs.append(Double(nowNs &- s.eventTimestampNs) / 1e6)
        }
    }

    func summary(expectedHz: Double) -> String {
        let frames = LatencyStats(label: "frame.interval", samples: frameIntervalsMs)
        let ages = LatencyStats(label: "input.ageAtFrame", samples: inputAgesMs)
        let expectedMs = 1000.0 / expectedHz
        let dropped = frameIntervalsMs.filter { $0 > expectedMs * 1.6 }.count
        return """
        frames rendered:     \(framesRendered)
        scroll samples:      \(samplesConsumed)
        frame interval:      p50=\(String(format: "%.2f", frames.percentile(50)))ms \
        p95=\(String(format: "%.2f", frames.percentile(95)))ms \
        p99=\(String(format: "%.2f", frames.percentile(99)))ms \
        max=\(String(format: "%.2f", frames.max))ms (budget \(String(format: "%.2f", expectedMs))ms)
        dropped frames:      \(dropped) (>1.6x budget)
        input age at frame:  p50=\(String(format: "%.2f", ages.percentile(50)))ms \
        p95=\(String(format: "%.2f", ages.percentile(95)))ms \
        max=\(String(format: "%.2f", ages.max))ms
        """
    }
}

// MARK: - Overlay view + renderer

final class OverlayView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = nil
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

final class OverlayRenderer: NSObject {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let instanceBuffer: MTLBuffer
    private let instanceCount: Int

    private let view: OverlayView
    private let inputQueue: ScrollInputQueue
    private var viewport = ViewportPhysics()
    let metrics = OverlayMetrics()

    private var displayLink: CADisplayLink?
    private var lastStepNs: UInt64 = 0

    init?(view: OverlayView, inputQueue: ScrollInputQueue, screenSize: CGSize) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.view = view
        self.inputQueue = inputQueue

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one // premultiplied
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal pipeline error: \(error)")
            return nil
        }

        let windows = FakeCanvas.makeWindows(screen: screenSize)
        instanceCount = windows.count
        guard let buffer = device.makeBuffer(
            bytes: windows,
            length: MemoryLayout<InstanceData>.stride * windows.count,
            options: .storageModeShared
        ) else { return nil }
        instanceBuffer = buffer

        view.metalLayer.device = device
        super.init()
    }

    func start() {
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let nowNs = Clock.nowAbsNs()
        let dt = lastStepNs == 0 ? 1.0 / 120.0 : Double(nowNs &- lastStepNs) / 1e9
        lastStepNs = nowNs

        // 1. Input
        let samples = inputQueue.drain()
        viewport.apply(samples: samples, nowNs: nowNs)
        viewport.coast(dt: dt, nowNs: nowNs)
        metrics.onFrame(nowNs: nowNs, consumed: samples)

        // 2. Render
        guard let drawable = view.metalLayer.nextDrawable() else { return }
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        // Slight dim so the user can see overlay mode is active.
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0.25)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        var uniforms = Uniforms(
            viewportOrigin: SIMD2<Float>(Float(viewport.origin.x), Float(viewport.origin.y)),
            screenSize: SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        encoder.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - Synthetic scroll generator (selftest)

/// Posts ctrl+opt scroll events so latency can be measured with no human input.
/// Our own tap suppresses them, so user apps never see these events.
final class SelfTestScroller {
    private var thread: Thread?
    private(set) var posted = 0

    func start(durationSeconds: Double) {
        let thread = Thread { [weak self] in
            let endTime = Date().addingTimeInterval(durationSeconds)
            var phase = 0.0
            while Date() < endTime {
                // Sinusoidal velocity envelope, like a human pan gesture.
                phase += 0.008
                let dy = sin(phase) * 18.0
                if let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(dy),
                    wheel2: Int32(cos(phase * 0.7) * 9.0),
                    wheel3: 0
                ) {
                    event.flags = ScrollEventTap.requiredFlags
                    event.timestamp = Clock.nowAbsNs()
                    event.post(tap: .cghidEventTap)
                    self?.posted += 1
                }
                Thread.sleep(forTimeInterval: 1.0 / 120.0) // 120 events/sec
            }
        }
        thread.name = "scrollwm.selftest"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }
}

// MARK: - Entry

func runOverlay(seconds: Int, selftest: Bool) {
    guard AXSource.isTrusted else {
        print("AX: NOT TRUSTED. Event tap needs Accessibility permission.")
        exit(2)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
        print("no screen")
        exit(1)
    }
    let refreshHz = Double(screen.maximumFramesPerSecond)

    // Overlay window: borderless, transparent, above normal windows,
    // click-through, on all Spaces.
    let window = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.level = .statusBar
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
    window.contentView = view
    window.orderFrontRegardless()
    view.updateDrawableSize()

    // Input
    let inputQueue = ScrollInputQueue()
    let tap = ScrollEventTap(queue: inputQueue)
    guard tap.start() else {
        print("Failed to create event tap. Check Accessibility / Input Monitoring permission.")
        exit(2)
    }

    // Renderer
    guard let renderer = OverlayRenderer(view: view, inputQueue: inputQueue, screenSize: screen.frame.size) else {
        print("Failed to create Metal renderer.")
        exit(1)
    }
    renderer.start()

    let scroller = SelfTestScroller()
    if selftest {
        scroller.start(durationSeconds: Double(seconds) - 1.0)
        print("Selftest: posting synthetic ctrl+opt scroll events (suppressed before reaching apps).")
    }

    print("Overlay running \(seconds)s on \(Int(screen.frame.width))x\(Int(screen.frame.height)) @ \(Int(refreshHz))Hz.")
    print("Hold CTRL+OPTION and scroll to pan the canvas. Clicks pass through.")

    // Per-second progress line.
    var secondsElapsed = 0
    let progressTimer = Timer(timeInterval: 1.0, repeats: true) { _ in
        secondsElapsed += 1
        let m = renderer.metrics
        let recent = m.frameIntervalsMs.suffix(Int(refreshHz))
        let maxMs = recent.max() ?? 0
        print(String(
            format: "  [%2ds] frames=%-5d events=%-5d tapDisables=%d maxFrame=%.2fms",
            secondsElapsed, m.framesRendered, m.samplesConsumed, tap.tapDisableCount, maxMs
        ))
    }
    RunLoop.main.add(progressTimer, forMode: .common)

    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
        progressTimer.invalidate()
        renderer.stop()
        tap.stop()
        window.orderOut(nil)
        print("\n== Overlay metrics ==")
        print(renderer.metrics.summary(expectedHz: refreshHz))
        if selftest {
            print("synthetic events posted: \(scroller.posted)")
        }
        if tap.tapDisableCount > 0 {
            print("WARNING: event tap was disabled \(tap.tapDisableCount) time(s) by the system")
        }
        exit(0)
    }

    app.run()
}
