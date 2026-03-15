import AVKit
import Foundation

/// Convenience wrapper that creates an `AVPictureInPictureController`
/// backed by an `MPVPixelBufferBridge`'s display layer.
@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)
public final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    private let bridge: MPVPixelBufferBridge
    private let playbackDelegate: PiPPlaybackDelegate
    private var controller: AVPictureInPictureController?

    /// Called when PiP starts.
    public var onStarted: (() -> Void)?
    /// Called when PiP stops. The Bool indicates whether the user requested restore.
    public var onStopped: ((Bool) -> Void)?
    /// Called when the user taps the restore button in PiP. Return true if handled.
    public var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)?

    public init(bridge: MPVPixelBufferBridge,
                playbackDelegate: PiPPlaybackDelegate = PiPPlaybackDelegate()) {
        self.bridge = bridge
        self.playbackDelegate = playbackDelegate
        super.init()
        configureController()
    }

    public var isPictureInPicturePossible: Bool {
        controller?.isPictureInPicturePossible ?? false
    }

    public var isPictureInPictureActive: Bool {
        controller?.isPictureInPictureActive ?? false
    }

    public func start() {
        controller?.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    public func invalidate() {
        stop()
        controller?.delegate = nil
        controller = nil
    }

    private func configureController() {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: bridge.displayLayer,
            playbackDelegate: playbackDelegate
        )
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
    }

    // MARK: - AVPictureInPictureControllerDelegate

    public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("PiP: will start")
    }

    public func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("PiP: did start")
        onStarted?()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        print("PiP: failed to start: \(error.localizedDescription)")
    }

    public func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("PiP: will stop")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("PiP: did stop")
        onStopped?(false)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        print("PiP: restore user interface requested")
        if let onRestoreUserInterface {
            onRestoreUserInterface(completionHandler)
        } else {
            completionHandler(true)
        }
    }
}
