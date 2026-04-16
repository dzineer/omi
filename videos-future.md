# Videos — Future Use

Captured for later integration. These videos are currently deferred (onboarding is skipped via `hasCompletedOnboarding=true` in UserDefaults, so `omi-demo.mp4` doesn't play right now). Save these details so we can re-enable or repurpose the videos once VibeAi-branded replacements are produced.

## 1. omi-demo.mp4 (onboarding hero video)

- **Path**: `desktop/Desktop/Sources/Resources/omi-demo.mp4`
- **Size**: 2,722,343 bytes (~2.7 MB)
- **Duration**: 26.004 seconds
- **Resolution**: 960 x 540 (16:9, 540p)
- **Frame rate**: 30 fps (780 frames total)
- **Video codec**: H.264 / AVC, High profile, Level 3.1
- **Audio codec**: MPEG-4 AAC
- **Pixel format**: yuvj420p (full-range JPEG-style)
- **Bitrate**: ~510 kbps video
- **Container**: ISO Media / MP4 Base Media v1 (ISO 14496-12:2003)
- **Created**: 2026-02-28
- **Loaded from**: `Bundle.resourceBundle.url(forResource: "omi-demo", withExtension: "mp4")`
- **Played by**: `desktop/Desktop/Sources/OnboardingView.swift:227` — `OnboardingVideoView` (AVPlayerView)
- **Content**: "Meet Omi" branded intro — "Your proactive AI that sees, hears, and helps"
- **Why deferred**: Contains "Meet Omi" text baked into the video frames, not compatible with VibeAi branding. Needs re-rendering or replacement.
- **Future action**: Re-render with VibeAi branding ("Meet VibeAi", blue/orange palette matching the wordmark logo) OR replace with a native SwiftUI intro animation that reads from text + Lottie files.

## 2. demo.mp4 (consumer watch band hardware)

- **Path**: `omi/hardware/consumer-watch-band/1.5cm-watch-band-case/demo.mp4`
- **Size**: 576,832 bytes (~563 KB)
- **Duration**: 10.417 seconds
- **Resolution**: 1920 x 1080 (16:9, 1080p)
- **Frame rate**: 24 fps (250 frames total)
- **Video codec**: H.264 / AVC, High profile, Level 4.0
- **Audio codec**: none (video only)
- **Pixel format**: yuv420p (TV-range)
- **Bitrate**: ~440 kbps video
- **Container**: ISO Media / MP4 Base Media v1 (ISO 14496-12:2003)
- **Created**: 2026-02-28
- **Context**: Hardware demo for the 1.5cm Omi watch band case — product visualization.
- **Not yet wired into the app**. Lives under `omi/hardware/`, which is the hardware design folder (STL files, schematics, product photos).
- **Why deferred**: Hardware-specific content; may be useful later if VibeAi ships a companion wearable or needs a product reel.
- **Future action**: Candidate for the Dashboard's "Get Device" widget (currently removed from sidebar per user preferences), or a future VibeAi hardware showcase page.

## Implementation Notes

- Both videos are H.264/AAC MP4 — universally playable by `AVPlayer` on macOS without extra decoders.
- Neither is currently shown in the app (onboarding skipped; hardware video unreferenced in Swift).
- Do NOT delete either file — keeping them in the repo so we can re-enable or re-encode later.
- When replacing `omi-demo.mp4`, preserve the same dimensions (960x540) and duration (~26s) so the `AVPlayerView` layout doesn't need to change.
