# MPVKit (Drvolks Fork)

[![mpv](https://img.shields.io/badge/mpv-v0.41.0-blue.svg)](https://github.com/mpv-player/mpv)
[![ffmpeg](https://img.shields.io/badge/ffmpeg-n8.0.1-blue.svg)](https://github.com/FFmpeg/FFmpeg)
[![license](https://img.shields.io/github/license/mpvkit/MPVKit)](https://github.com/mpvkit/MPVKit/main/LICENSE)

Fork of [mpvkit/MPVKit](https://github.com/mpvkit/MPVKit) with a custom video output plugin and Swift bridge for `AVSampleBufferDisplayLayer` rendering and native Picture-in-Picture support on Apple platforms.

## What's Different from Upstream

This fork adds two things on top of MPVKit 0.41.0:

### 1. `vo_pixelbuffer` - Custom Video Output Plugin

A new mpv VO (`vo=pixelbuffer`) that extracts decoded video frames as `CVPixelBufferRef` and delivers them via C callback to the Swift layer. This replaces the OpenGL ES / Metal GPU rendering path with `AVSampleBufferDisplayLayer` output.

**Why:**
- Eliminates the deprecated `GLKView` / OpenGL ES dependency
- Enables native system PiP (requires `AVSampleBufferDisplayLayer`)
- Handles HDR/10-bit content natively (p010 format)
- Minimal mpv diff: 1 new C file + ~5 lines changed in existing files

**How it works:**
- The VO sits at the end of mpv's video pipeline, receiving perfectly timed frames with A/V sync already applied
- For `hwdec=videotoolbox-copy`: hardware decode produces NV12 frames, the VO creates IOSurface-backed `CVPixelBuffer` copies
- For software decode: mpv auto-converts to NV12 (the VO only accepts NV12 and VIDEOTOOLBOX formats), then same IOSurface copy path
- The Swift callback enqueues frames as `CMSampleBuffer` to `AVSampleBufferDisplayLayer`

**Files:**
- `video/out/vo_pixelbuffer.c` - The VO plugin (applied via build patch)
- `include/mpv/render_pixelbuffer.h` - Public C API for callback registration
- `Sources/BuildScripts/patch/libmpv/0003-add-vo-pixelbuffer-output.patch` - Build system patch

### 2. `MPVPixelBufferBridge` - Swift Package Target

A Swift library that bridges `vo_pixelbuffer` to `AVSampleBufferDisplayLayer` and provides PiP support.

**Components:**
- `MPVPixelBufferBridge` - Receives `CVPixelBuffer` frames via C callback, creates `CMSampleBuffer` with monotonic realtime PTS, enqueues to `AVSampleBufferDisplayLayer` with a synchronized `CMTimebase`
- `PiPController` - Wraps `AVPictureInPictureController` with `sampleBufferDisplayLayer` content source (iOS 15+)
- `PiPPlaybackDelegate` - `AVPictureInPictureSampleBufferPlaybackDelegate` with closures for play/pause integration

## Installation

### Swift Package Manager

```
https://github.com/Drvolks/MPVKit.git
```

Use exact version `0.41.0-drvolks.1` or the `feature/pixelbuffer-vo` branch.

Add both products to your target:

```swift
dependencies: [
    .package(url: "https://github.com/Drvolks/MPVKit.git", exact: "0.41.0-drvolks.1")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MPVKit", package: "MPVKit"),
            .product(name: "MPVPixelBufferBridge", package: "MPVKit"),
        ]
    )
]
```

## Using the PixelBuffer Renderer

### Basic Setup (No PiP)

```swift
import Libmpv
import MPVPixelBufferBridge

// 1. Create the bridge with a display layer
let displayLayer = AVSampleBufferDisplayLayer()
let bridge = MPVPixelBufferBridge(displayLayer: displayLayer)

// 2. Register callbacks BEFORE mpv_initialize
bridge.attach()

// 3. Create and configure mpv
let mpv = mpv_create()
mpv_set_option_string(mpv, "vo", "pixelbuffer")     // Use the pixelbuffer VO
mpv_set_option_string(mpv, "hwdec", "auto-safe")     // Will pick videotoolbox-copy
mpv_set_option_string(mpv, "hwdec-codecs", "h264,hevc,av1")
mpv_initialize(mpv)

// 4. Add the display layer to your view
view.layer.addSublayer(displayLayer)
displayLayer.frame = view.bounds

// 5. Load and play
mpv_command_string(mpv, "loadfile \"https://example.com/video.mp4\"")
```

The bridge handles everything: frame reception, `CMSampleBuffer` creation with IOSurface-backed `CVPixelBuffer`, monotonic PTS generation, and `AVSampleBufferDisplayLayer` enqueue/recovery.

### With PiP (iOS 15+)

```swift
import MPVPixelBufferBridge

// After bridge and mpv are set up and playing:

// 1. Configure audio session for background playback
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
try AVAudioSession.sharedInstance().setActive(true)

// 2. Create PiP controller
let delegate = PiPPlaybackDelegate()
delegate.onSetPlaying = { playing in
    // Forward to mpv play/pause
}
delegate.isPaused = {
    // Return mpv's pause state
}

let pipController = PiPController(bridge: bridge, playbackDelegate: delegate)

// 3. Handle PiP lifecycle
pipController.onStopped = { _ in
    // PiP window closed
}
pipController.onRestoreUserInterface = { completion in
    // User tapped expand - re-show fullscreen player
    completion(true)
}

// 4. Start PiP
pipController.start()
```

**Important for PiP:**
- The `AVSampleBufferDisplayLayer` must be backed by IOSurface (the bridge handles this)
- The audio session must be `.playback` category before PiP starts
- mpv must keep running when the app goes to background - don't pause on `willResignActive`
- The bridge and mpv must outlive the SwiftUI view (use a singleton session pattern)
- PiP only works on real devices, not simulators

### Flush on Seek

When seeking, flush the display layer to avoid showing stale frames:

```swift
bridge.flush()  // Call on @MainActor after seek
```

### Reconfig Callback

Monitor video format changes:

```swift
bridge.onReconfig = { width, height, format in
    print("Video: \(width)x\(height) format=\(format)")
}
```

## Choose Which Version

| Version | License | Note |
|---|---|---|
| MPVKit | LGPL | [FFmpeg details](https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md), [mpv details](https://github.com/mpv-player/mpv/blob/master/Copyright) |
| MPVKit-GPL | GPL | Support samba protocol, same as old MPVKit version |

## How to Build

```bash
make build
# specified platforms (ios,macos,tvos,tvsimulator,isimulator,maccatalyst,xros,xrsimulator)
make build platform=ios,macos
# build GPL version
make build enable-gpl
# clean all build temp files and cache
make clean
# see help
make help
```

The build system applies patches from `Sources/BuildScripts/patch/libmpv/` to the cloned mpv source, including the `vo_pixelbuffer` patch.

## About Metal Support

Metal support is only a patch version ([#7857](https://github.com/mpv-player/mpv/pull/7857)) and does not officially support it yet. The pixelbuffer renderer is an alternative that avoids both Metal and OpenGL rendering paths entirely.

## Fork Maintenance

- `main` branch tracks upstream `mpvkit/MPVKit`
- `feature/pixelbuffer-vo` branch has all modifications
- Total diff: ~1 new C file + ~5 lines in existing mpv files + Swift bridge package
- Rebase on upstream: `git fetch upstream && git rebase upstream/main feature/pixelbuffer-vo`

## Related Projects

* [mpvkit/MPVKit](https://github.com/mpvkit/MPVKit) (upstream)
* [moltenvk-build](https://github.com/mpvkit/moltenvk-build)
* [libplacebo-build](https://github.com/mpvkit/libplacebo-build)
* [libdovi-build](https://github.com/mpvkit/libdovi-build)
* [libshaderc-build](https://github.com/mpvkit/libshaderc-build)
* [libluajit-build](https://github.com/mpvkit/libluajit-build)
* [libass-build](https://github.com/mpvkit/libass-build)
* [libbluray-build](https://github.com/mpvkit/libbluray-build)
* [libsmbclient-build](https://github.com/mpvkit/libsmbclient-build)
* [gnutls-build](https://github.com/mpvkit/gnutls-build)
* [openssl-build](https://github.com/mpvkit/openssl-build)

## License

`MPVKit` source alone is licensed under the LGPL v3.0.

`MPVKit` bundles (`frameworks`, `xcframeworks`), which include both `libmpv` and `FFmpeg` libraries, are also licensed under the LGPL v3.0. However, if the source code is built using the optional `enable-gpl` flag or prebuilt binaries with `-GPL` postfix are used, then `MPVKit` bundles become subject to the GPL v3.0.
