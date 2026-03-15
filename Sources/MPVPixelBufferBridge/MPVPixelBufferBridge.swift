import AVFoundation
import CoreMedia
import CoreVideo

// The C function is defined in vo_pixelbuffer.c and exposed via render_pixelbuffer.h.
// When using pre-built xcframeworks that don't yet include the header, we declare it here.
// This declaration matches the signature in include/mpv/render_pixelbuffer.h.
private typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Double, Double) -> Void
private typealias ReconfigCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void

@_silgen_name("mpv_pixelbuffer_set_callbacks")
private func _mpv_pixelbuffer_set_callbacks(
    _ frame_cb: FrameCallback?,
    _ frame_ctx: UnsafeMutableRawPointer?,
    _ reconfig_cb: ReconfigCallback?,
    _ reconfig_ctx: UnsafeMutableRawPointer?
)

/// Receives CVPixelBuffer frames from mpv's `vo=pixelbuffer` output and
/// delivers them to an `AVSampleBufferDisplayLayer` for native Metal display
/// and system PiP support.
///
/// Usage:
/// 1. Create a `MPVPixelBufferBridge` instance
/// 2. Call `attach()` before `mpv_initialize()`
/// 3. Use `displayLayer` with your view and PiP controller
public final class MPVPixelBufferBridge: NSObject, @unchecked Sendable {
    public let displayLayer: AVSampleBufferDisplayLayer

    private let lock = NSLock()
    private var lastPTS: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var videoWidth: Int32 = 0
    private var videoHeight: Int32 = 0
    private let minimumStep = CMTime(value: 1_500, timescale: 90_000) // ~16.6ms

    /// Callback invoked on the main thread when the video reconfigures
    /// (resolution or format change). Parameters: (width, height, format).
    public var onReconfig: ((Int32, Int32, Int32) -> Void)?

    public override convenience init() {
        self.init(displayLayer: AVSampleBufferDisplayLayer())
    }

    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        displayLayer.videoGravity = .resizeAspect
        setupControlTimebase()
    }

    private func setupControlTimebase() {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard status == noErr, let timebase else {
            print("PixelBufferBridge: failed to create control timebase: \(status)")
            return
        }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(timebase, rate: 1.0)
        displayLayer.controlTimebase = timebase
        print("PixelBufferBridge: control timebase set")
    }

    /// Register the pixelbuffer callbacks with mpv. Must be called before
    /// `mpv_initialize()`.
    public func attach() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _mpv_pixelbuffer_set_callbacks(frameCallback, ctx, reconfigCallback, ctx)
    }

    /// Flush the display layer (call on seek/reset).
    @MainActor
    public func flush() {
        displayLayer.flushAndRemoveImage()
        lock.withLock {
            lastPTS = nil
            lastFrame = nil
        }
    }

    /// Re-enqueue the last frame after a flush (e.g. returning from PiP).
    @MainActor
    public func primeFromLatestFrame() {
        let pb = lock.withLock { lastFrame }
        guard let pb else { return }
        let pts = makeMonotonicRealtimePTS()
        guard let sampleBuffer = makeSampleBuffer(
            from: pb, presentationTimeStamp: pts, displayImmediately: false
        ) else { return }
        recoverAndEnqueue(sampleBuffer)
    }

    // MARK: - Internal (accessible from file-scope C callbacks)

    private var frameCount = 0

    fileprivate func handleFrame(pixelBuffer: CVPixelBuffer, pts: Double, duration: Double) {
        lock.withLock {
            lastFrame = pixelBuffer
            frameCount += 1
        }
        let count = lock.withLock { frameCount }
        if count == 1 || count % 300 == 0 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let formatStr = String(format: "%c%c%c%c",
                                   (pixelFormat >> 24) & 0xFF,
                                   (pixelFormat >> 16) & 0xFF,
                                   (pixelFormat >> 8) & 0xFF,
                                   pixelFormat & 0xFF)
            print("PixelBufferBridge: frame #\(count) \(w)x\(h) pts=\(String(format: "%.3f", pts)) ioSurface=\(hasIOSurface) fmt=\(formatStr)")
        }
        let realtimePTS = makeMonotonicRealtimePTS()
        guard let sampleBuffer = makeSampleBuffer(
            from: pixelBuffer, presentationTimeStamp: realtimePTS, displayImmediately: true
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recoverAndEnqueue(sampleBuffer)
            if count == 1 {
                print("PixelBufferBridge: first frame enqueued, layer.status=\(self.displayLayer.status.rawValue), hasSufficientMediaData=\(self.displayLayer.isReadyForMoreMediaData)")
            }
        }
    }

    fileprivate func handleReconfig(w: Int32, h: Int32, fmt: Int32) {
        print("PixelBufferBridge: reconfig \(w)x\(h) fmt=\(fmt)")
        lock.withLock {
            videoWidth = w
            videoHeight = h
        }
        onReconfig?(w, h, fmt)
    }

    // MARK: - Private

    @MainActor
    private func recoverAndEnqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeMonotonicRealtimePTS() -> CMTime {
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastPTS else {
            lastPTS = pts
            return pts
        }
        if pts > last {
            lastPTS = pts
            return pts
        }
        let adjusted = last + minimumStep
        lastPTS = adjusted
        return adjusted
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        displayImmediately: Bool
    ) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        guard fmtStatus == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 3_000, timescale: 90_000),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let bufStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufStatus == noErr, let sampleBuffer else { return nil }

        if displayImmediately,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sampleBuffer, createIfNecessary: true
           ) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

// MARK: - C Callbacks

/// Frame callback invoked by vo_pixelbuffer on mpv's VO thread.
private func frameCallback(ctx: UnsafeMutableRawPointer?,
                           pixelBuffer: UnsafeMutableRawPointer?,
                           pts: Double, duration: Double) {
    guard let ctx, let pixelBuffer else { return }
    let bridge = Unmanaged<MPVPixelBufferBridge>.fromOpaque(ctx).takeUnretainedValue()
    // CVPixelBuffer is automatically managed by Swift ARC — unsafeBitCast retains it.
    let pb = unsafeBitCast(pixelBuffer, to: CVPixelBuffer.self)
    bridge.handleFrame(pixelBuffer: pb, pts: pts, duration: duration)
}

/// Reconfig callback invoked by vo_pixelbuffer on mpv's VO thread.
private func reconfigCallback(ctx: UnsafeMutableRawPointer?,
                              w: Int32, h: Int32, fmt: Int32) {
    guard let ctx else { return }
    let bridge = Unmanaged<MPVPixelBufferBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.handleReconfig(w: w, h: h, fmt: fmt)
}
