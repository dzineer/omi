import Foundation

/// Local speech-to-text service that replaces cloud-based TranscriptionService.
/// Routes to MLX Whisper (Apple Silicon) or ONNX Whisper (x86/fallback).
/// Accumulates audio, and when signaled (VAD speech-end or stopListening),
/// encodes as WAV and transcribes locally.
actor LocalSTTService {

    // MARK: - Types

    /// Callback delivering transcript text when ready.
    typealias TranscriptHandler = @Sendable (String) -> Void

    /// Callback for errors.
    typealias ErrorHandler = @Sendable (Error) -> Void

    /// Callback for state changes.
    typealias StateHandler = @Sendable (ServiceState) -> Void

    enum ServiceState: Sendable {
        case idle
        case listening
        case transcribing
        case error(String)
    }

    enum STTError: LocalizedError {
        case notListening
        case noAudioData
        case noEngineAvailable
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notListening:
                return "LocalSTTService is not listening"
            case .noAudioData:
                return "No audio data to transcribe"
            case .noEngineAvailable:
                return "No STT engine available (MLX or ONNX)"
            case .transcriptionFailed(let reason):
                return "Local transcription failed: \(reason)"
            }
        }
    }

    enum EngineType {
        case mlxWhisper
        case onnxWhisper
    }

    // MARK: - Properties

    private var audioBuffer = Data()
    private var isListening = false
    private var state: ServiceState = .idle

    private var mlxServer: MLXWhisperServer?
    private var onnxEngine: WhisperONNXEngine?
    private var activeEngine: EngineType?

    private let sampleRate: UInt32 = 16000
    private let bitsPerSample: UInt16 = 16
    private let numChannels: UInt16 = 1

    private let language: String

    // Callbacks
    private var onTranscript: TranscriptHandler?
    private var onError: ErrorHandler?
    private var onStateChanged: StateHandler?

    // MARK: - Initialization

    /// Initialize the local STT service.
    /// - Parameter language: Language code for transcription (default: "en")
    init(language: String = "en") {
        self.language = language
        log("LocalSTTService: Initialized with language=\(language)")
    }

    // MARK: - Public Interface

    /// Configure callbacks for receiving transcripts, errors, and state changes.
    func configure(
        onTranscript: @escaping TranscriptHandler,
        onError: ErrorHandler? = nil,
        onStateChanged: StateHandler? = nil
    ) {
        self.onTranscript = onTranscript
        self.onError = onError
        self.onStateChanged = onStateChanged
    }

    /// Start listening for audio. Initializes the appropriate engine.
    func startListening() async {
        guard !isListening else {
            log("LocalSTTService: Already listening")
            return
        }

        audioBuffer = Data()
        isListening = true
        updateState(.listening)

        // Select and initialize engine
        await initializeEngine()

        log("LocalSTTService: Started listening (engine: \(String(describing: activeEngine)))")
    }

    /// Stop listening and transcribe any remaining audio.
    func stopListening() async {
        guard isListening else { return }

        isListening = false
        log("LocalSTTService: Stopping, buffer has \(audioBuffer.count) bytes")

        // Transcribe remaining audio
        if !audioBuffer.isEmpty {
            await transcribeBuffer()
        }

        updateState(.idle)
    }

    /// Receive PCM16 16kHz audio data from AudioCaptureService.
    /// In a local STT workflow, audio is accumulated until speechEnded() is called
    /// (by VAD) or stopListening() is called.
    func sendAudio(_ data: Data) {
        guard isListening else { return }
        audioBuffer.append(data)
    }

    /// Signal that VAD detected speech end. Triggers transcription of the
    /// accumulated audio buffer and resets for the next utterance.
    func speechEnded() async {
        guard isListening else { return }
        guard !audioBuffer.isEmpty else { return }

        log("LocalSTTService: Speech ended, transcribing \(audioBuffer.count) bytes")
        await transcribeBuffer()
    }

    /// Check if the service is currently listening.
    var listening: Bool {
        isListening
    }

    /// Get the current service state.
    var currentState: ServiceState {
        state
    }

    /// Shut down engines and release resources.
    func shutdown() async {
        isListening = false
        audioBuffer = Data()

        if let server = mlxServer {
            await server.stop()
            mlxServer = nil
        }
        onnxEngine = nil
        activeEngine = nil

        updateState(.idle)
        log("LocalSTTService: Shut down")
    }

    // MARK: - Private

    /// Select and initialize the best available engine.
    private func initializeEngine() async {
        // Try MLX Whisper on Apple Silicon (shared singleton server)
        if MLXWhisperServer.isAppleSilicon() {
            let server = MLXWhisperServer.shared
            do {
                try await server.start()
                mlxServer = server
                activeEngine = .mlxWhisper
                log("LocalSTTService: Using MLX Whisper engine (shared)")
                return
            } catch {
                logError("LocalSTTService: MLX Whisper unavailable, trying ONNX fallback", error: error)
            }
        } else if mlxServer != nil, await mlxServer!.isRunning {
            activeEngine = .mlxWhisper
            return
        }

        // Fall back to ONNX
        if onnxEngine == nil {
            do {
                onnxEngine = try WhisperONNXEngine()
                activeEngine = .onnxWhisper
                log("LocalSTTService: Using ONNX Whisper engine")
                return
            } catch {
                logError("LocalSTTService: ONNX Whisper also unavailable", error: error)
            }
        } else {
            activeEngine = .onnxWhisper
            return
        }

        logError("LocalSTTService: No STT engine available", error: nil)
        updateState(.error("No local STT engine available"))
        onError?(STTError.noEngineAvailable)
    }

    /// Encode the audio buffer as WAV, send to the active engine, and deliver the result.
    private func transcribeBuffer() async {
        let pcmData = audioBuffer
        audioBuffer = Data()

        guard !pcmData.isEmpty else { return }

        updateState(.transcribing)

        let wavData = encodeWAV(pcmData: pcmData)

        // Debug: save WAV to disk so we can test it manually
        let debugPath = "/tmp/local-stt-debug.wav"
        try? wavData.write(to: URL(fileURLWithPath: debugPath))
        log("LocalSTTService: Saved debug WAV to \(debugPath) (\(wavData.count) bytes, pcm=\(pcmData.count) bytes)")

        do {
            var text: String?

            switch activeEngine {
            case .mlxWhisper:
                if let server = mlxServer {
                    text = try await server.transcribe(wavData: wavData, language: language)
                }
            case .onnxWhisper:
                if let engine = onnxEngine {
                    text = try engine.transcribe(wavData: wavData)
                }
            case .none:
                throw STTError.noEngineAvailable
            }

            if let text = text, !text.isEmpty {
                if HallucinationFilter.isHallucination(text) {
                    log("LocalSTTService: Filtered hallucination: \(text)")
                } else {
                    log("LocalSTTService: Transcript: \(text.prefix(80))")
                    onTranscript?(text)
                }
            }

            if isListening {
                updateState(.listening)
            } else {
                updateState(.idle)
            }
        } catch {
            logError("LocalSTTService: Transcription failed", error: error)
            onError?(error)
            if isListening {
                updateState(.listening)
            } else {
                updateState(.error(error.localizedDescription))
            }
        }
    }

    /// Encode raw PCM16 mono 16kHz data into a WAV byte buffer.
    /// WAV format: 44-byte header + raw PCM data.
    private func encodeWAV(pcmData: Data) -> Data {
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize  // Total file size minus 8 bytes for RIFF header
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var wav = Data()
        wav.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.append(littleEndianUInt32: fileSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt subchunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        wav.append(littleEndianUInt32: 16)                 // Subchunk1 size (PCM = 16)
        wav.append(littleEndianUInt16: 1)                  // Audio format (PCM = 1)
        wav.append(littleEndianUInt16: numChannels)        // Num channels
        wav.append(littleEndianUInt32: sampleRate)         // Sample rate
        wav.append(littleEndianUInt32: byteRate)           // Byte rate
        wav.append(littleEndianUInt16: blockAlign)         // Block align
        wav.append(littleEndianUInt16: bitsPerSample)      // Bits per sample

        // data subchunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        wav.append(littleEndianUInt32: dataSize)
        wav.append(pcmData)

        return wav
    }

    private func updateState(_ newState: ServiceState) {
        state = newState
        let handler = onStateChanged
        let captured = newState
        Task { @MainActor in
            handler?(captured)
        }
    }
}

// MARK: - Data Extensions for WAV Encoding

private extension Data {
    mutating func append(littleEndianUInt32 value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }

    mutating func append(littleEndianUInt16 value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }
}
