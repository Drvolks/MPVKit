import AVKit
import CoreMedia
import Foundation

/// Minimal `AVPictureInPictureSampleBufferPlaybackDelegate` for live-stream-style
/// playback (no seeking, infinite time range). The consuming app can subclass or
/// replace this to add pause/play/skip integration with mpv.
@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)
public final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Called by the system when PiP requests play/pause.
    /// Set this closure to forward play/pause to mpv.
    public var onSetPlaying: ((Bool) -> Void)?

    /// Called by the system to query pause state.
    /// Set this closure to return mpv's current pause state.
    public var isPaused: (() -> Bool)?

    public override init() {
        super.init()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        onSetPlaying?(playing)
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        isPaused?() ?? false
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}
