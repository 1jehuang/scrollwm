import Foundation
import ScreenCaptureKit
import CoreMedia
import Metal
import CoreVideo
import AppKit

/// Milestone 4 (v2 groundwork): measure ScreenCaptureKit window capture
/// latency and IOSurface -> MTLTexture conversion cost. This decides how
/// fresh "cinematic mode" proxies can actually be.
final class CaptureBenchmark: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    // Metrics
    private var frameCount = 0
    private var captureAgesMs: [Double] = []     // presentation -> receipt
    private var conversionsMs: [Double] = []     // IOSurface -> MTLTexture
    private var firstFrameMs: Double = 0         // stream start -> first frame
    private var streamStartNs: UInt64 = 0

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func run(seconds: Int) async throws {
        // Pick a target window: largest on-screen window not owned by us.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let target = content.windows
            .filter({ $0.owningApplication?.processID != myPID && $0.frame.width >= 300 && $0.frame.height >= 200 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            print("no capturable window found")
            return
        }

        print("Capturing: \(target.owningApplication?.applicationName ?? "?") — \(target.title ?? "(untitled)") (\(Int(target.frame.width))x\(Int(target.frame.height)))")

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width) * 2     // retina
        config.height = Int(target.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture.frames", qos: .userInteractive))

        streamStartNs = Clock.nowAbsNs()
        try await stream.startCapture()
        print("Stream started; capturing \(seconds)s at up to 120fps...")

        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        try await stream.stopCapture()
        report(seconds: seconds)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let nowNs = Clock.nowAbsNs()
        frameCount += 1
        if frameCount == 1 {
            firstFrameMs = Double(nowNs &- streamStartNs) / 1e6
        }

        // Capture age: frame presentation timestamp -> now (mach time base).
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = UInt64(max(pts.seconds, 0) * 1e9)
        if ptsNs > 0 && ptsNs < nowNs {
            captureAgesMs.append(Double(nowNs &- ptsNs) / 1e6)
        }

        // IOSurface -> MTLTexture via texture cache (the hot-path operation).
        if let cache = textureCache {
            let start = Clock.nowAbsNs()
            var cvTexture: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture
            )
            if result == kCVReturnSuccess, let cvTexture, CVMetalTextureGetTexture(cvTexture) != nil {
                conversionsMs.append(Double(Clock.nowAbsNs() &- start) / 1e6)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("stream stopped with error: \(error.localizedDescription)")
    }

    private func report(seconds: Int) {
        let ages = LatencyStats(label: "capture.age", samples: captureAgesMs)
        let conv = LatencyStats(label: "texture.convert", samples: conversionsMs)
        let fps = Double(frameCount) / Double(seconds)
        print("\n== Capture benchmark ==")
        print(String(format: "  frames: %d (%.1f fps effective; idle windows emit fewer frames)", frameCount, fps))
        print(String(format: "  first frame after start: %.1f ms", firstFrameMs))
        print(String(format: "  capture age (pts->receipt): p50=%.2f p95=%.2f max=%.2f ms",
                     ages.percentile(50), ages.percentile(95), ages.max))
        print(String(format: "  IOSurface->MTLTexture:      p50=%.3f p95=%.3f max=%.3f ms",
                     conv.percentile(50), conv.percentile(95), conv.max))
        print("""

          interpretation:
          - capture age = staleness floor for cinematic-mode proxies
          - first-frame = warm-up cost when scroll begins (must hide with placeholder)
          - texture convert must stay well under 1ms to fit the 8.3ms budget
        """)
    }
}

func runCaptureBench(seconds: Int) {
    guard CaptureBenchmark.preflight() else {
        print("""
        Screen Recording permission NOT granted (this is expected for the v1 teleport tier).
        The capture benchmark needs it. To run this benchmark:
          System Settings -> Privacy & Security -> Screen & System Audio Recording
          add/enable: \(CommandLine.arguments[0])
        Requesting access (system will show a prompt)...
        """)
        CGRequestScreenCaptureAccess()
        exit(2)
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            try await CaptureBenchmark().run(seconds: seconds)
        } catch {
            print("capture error: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
}
