import Foundation
import AVFoundation

/// Plays PCM float32 audio buffers through the system default audio device.
/// Supports queueing multiple buffers and interrupting playback.
final class TTSAudioPlayer {

    // MARK: - Public Properties

    var volume: Float = 1.0 {
        didSet {
            playerNode.volume = volume
        }
    }

    private(set) var isPlaying: Bool = false

    var onPlaybackStarted: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let lock = NSLock()
    private var queue: [QueueEntry] = []
    private var isEngineRunning = false

    private struct QueueEntry {
        let buffer: AVAudioPCMBuffer
    }

    // MARK: - Init

    init() {
        engine.attach(playerNode)
        // Connect player node to main mixer at a default format; will reconnect per-buffer as needed
        let mainMixer = engine.mainMixerNode
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        engine.connect(playerNode, to: mainMixer, format: defaultFormat)
        playerNode.volume = volume
    }

    deinit {
        stopEngine()
    }

    // MARK: - Public Methods

    /// Play PCM float32 audio data at the given sample rate (mono).
    /// If already playing, the new audio is queued and played after the current buffer finishes.
    func play(_ audioData: Data, sampleRate: Int) {
        guard !audioData.isEmpty else { return }

        let sampleCount = audioData.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            logError("TTSAudioPlayer: Failed to create audio format for sample rate \(sampleRate)")
            return
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            logError("TTSAudioPlayer: Failed to create PCM buffer for \(sampleCount) samples")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy float32 data into the buffer
        audioData.withUnsafeBytes { rawPtr in
            guard let srcPtr = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            guard let dstPtr = pcmBuffer.floatChannelData?[0] else { return }
            dstPtr.update(from: srcPtr, count: sampleCount)
        }

        let entry = QueueEntry(buffer: pcmBuffer)

        lock.lock()
        let wasPlaying = isPlaying
        queue.append(entry)
        lock.unlock()

        if !wasPlaying {
            reconnectIfNeeded(format: format)
            ensureEngineRunning()
            scheduleNext()
        }
    }

    /// Stop current playback immediately and clear the queue.
    func stop() {
        lock.lock()
        queue.removeAll()
        let wasPlaying = isPlaying
        isPlaying = false
        lock.unlock()

        playerNode.stop()

        if wasPlaying {
            log("TTSAudioPlayer: Playback stopped by caller")
            onPlaybackFinished?()
        }
    }

    // MARK: - Private Methods

    private func reconnectIfNeeded(format: AVAudioFormat) {
        // Reconnect player node to main mixer with the correct format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    private func ensureEngineRunning() {
        guard !isEngineRunning else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            logError("TTSAudioPlayer: Failed to start audio engine", error: error)
        }
    }

    private func stopEngine() {
        playerNode.stop()
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
    }

    private func scheduleNext() {
        lock.lock()
        guard !queue.isEmpty else {
            let wasPlaying = isPlaying
            isPlaying = false
            lock.unlock()
            if wasPlaying {
                log("TTSAudioPlayer: Playback finished (queue empty)")
                onPlaybackFinished?()
            }
            return
        }

        let entry = queue.removeFirst()
        let isFirst = !isPlaying
        isPlaying = true
        lock.unlock()

        if isFirst {
            log("TTSAudioPlayer: Playback started")
            onPlaybackStarted?()
        }

        playerNode.scheduleBuffer(entry.buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleNext()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
}
