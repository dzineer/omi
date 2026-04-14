import Foundation
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#elseif canImport(onnxruntime)
import onnxruntime
#endif

// MARK: - Local TTS Service (Kokoro ONNX)

/// On-device text-to-speech using the Kokoro ONNX model.
/// Generates PCM float32 audio at 24kHz and plays it through TTSAudioPlayer.
actor LocalTTSService {

    // MARK: - Public Properties

    var isSpeaking: Bool {
        return player.isPlaying
    }

    // Callbacks (set from outside before calling speak)
    nonisolated var onSpeechStarted: (() -> Void)? {
        get { player.onPlaybackStarted }
        set { player.onPlaybackStarted = newValue }
    }

    nonisolated var onSpeechFinished: (() -> Void)? {
        get { player.onPlaybackFinished }
        set { player.onPlaybackFinished = newValue }
    }

    // MARK: - Constants

    private static let modelFileName = "kokoro-v1.0.onnx"
    private static let voicesFileName = "voices-v1.0.bin"
    private static let sampleRate = 24000
    private static let defaultVoice = "af_heart"
    /// Voice embedding dimension for Kokoro v1.0
    private static let voiceEmbeddingDim = 256

    // Download URLs for model files
    private static let modelDownloadURL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
    private static let voicesDownloadURL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

    // MARK: - Private Properties

    // nonisolated(unsafe) because TTSAudioPlayer is internally thread-safe (NSLock)
    // and we need to access it from nonisolated stop()/callback setters.
    nonisolated(unsafe) private let player = TTSAudioPlayer()
    private var isModelLoaded = false

#if canImport(OnnxRuntimeBindings) || canImport(onnxruntime)
    private var env: ORTEnv?
    private var session: ORTSession?
#endif

    /// Voice embeddings loaded from voices-v1.0.bin keyed by voice name.
    private var voiceEmbeddings: [String: [Float]] = [:]

    // MARK: - Public Methods

    /// Speak the given text using the default voice.
    func speak(_ text: String) async {
        await speak(text, voice: Self.defaultVoice)
    }

    /// Speak the given text using the specified voice.
    /// Tries Kokoro ONNX first; falls back to macOS `say` command if unavailable.
    func speak(_ text: String, voice: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Try Kokoro ONNX first
        do {
            try await ensureModelLoaded()
            if let audioData = generateAudio(text: trimmed, voice: voice) {
                log("LocalTTSService: Playing Kokoro audio (\(audioData.count) bytes)")
                player.play(audioData, sampleRate: Self.sampleRate)
                return
            }
        } catch {
            log("LocalTTSService: Kokoro unavailable (\(error.localizedDescription)), falling back to macOS say")
        }

        // Fallback: macOS say command (always available, less natural voice)
        await speakWithSay(trimmed)
    }

    /// Fallback TTS using macOS built-in `say` command.
    private func speakWithSay(_ text: String) async {
        log("LocalTTSService: Using macOS say fallback")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Use Samantha voice (best built-in English voice on macOS)
        proc.arguments = ["-v", "Samantha", "-r", "190", text]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            logError("LocalTTSService: say command failed", error: error)
        }
    }

    /// Stop current speech immediately.
    nonisolated func stop() {
        player.stop()
    }

    // MARK: - Model Loading

    private func ensureModelLoaded() async throws {
        guard !isModelLoaded else { return }

#if canImport(OnnxRuntimeBindings) || canImport(onnxruntime)
        let modelPath = try await ensureModelFile(Self.modelFileName, downloadURL: Self.modelDownloadURL)
        let voicesPath = try await ensureModelFile(Self.voicesFileName, downloadURL: Self.voicesDownloadURL)

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let sessionOptions = try ORTSessionOptions()
        try sessionOptions.setIntraOpNumThreads(2)
        let ortSession = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: sessionOptions)

        self.env = ortEnv
        self.session = ortSession

        loadVoiceEmbeddings(from: voicesPath)

        isModelLoaded = true
        log("LocalTTSService: Model loaded successfully from \(modelPath)")
#else
        log("LocalTTSService: ONNX Runtime not available -- TTS disabled")
        throw LocalTTSError.onnxNotAvailable
#endif
    }

    /// Returns the local file path for a model file, downloading it if not present.
    private func ensureModelFile(_ fileName: String, downloadURL: String) async throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let ttsDir = appSupport.appendingPathComponent("VoiceTTS", isDirectory: true)

        try FileManager.default.createDirectory(at: ttsDir, withIntermediateDirectories: true)

        let filePath = ttsDir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: filePath.path) {
            return filePath.path
        }

        log("LocalTTSService: Downloading \(fileName) from \(downloadURL)")

        guard let url = URL(string: downloadURL) else {
            throw LocalTTSError.invalidDownloadURL(downloadURL)
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LocalTTSError.downloadFailed(fileName, httpResponse.statusCode)
        }

        try FileManager.default.moveItem(at: tempURL, to: filePath)
        log("LocalTTSService: Downloaded \(fileName) to \(filePath.path)")

        return filePath.path
    }

    // MARK: - Voice Embeddings

    /// Load voice embeddings from the binary voices file.
    /// The file format is a flat binary of float32 arrays, indexed by voice name.
    /// For MVP we load the raw bytes and extract known voice embeddings.
    private func loadVoiceEmbeddings(from path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            logError("LocalTTSService: Could not read voices file at \(path)")
            return
        }

        // voices-v1.0.bin is a numpy .npy-like format: a dictionary of voice_name -> float32[256]
        // For now, treat the entire file as a flat array of float32 and use the default voice offset.
        // A full implementation would parse the file header to find voice name offsets.
        let totalFloats = data.count / MemoryLayout<Float>.size
        log("LocalTTSService: Voices file loaded (\(data.count) bytes, \(totalFloats) floats)")

        // Store raw data for later extraction. The actual format parsing happens in getVoiceEmbedding.
        voiceEmbeddings["__raw_data__"] = data.withUnsafeBytes { ptr in
            let floats = ptr.bindMemory(to: Float.self)
            return Array(floats)
        }
    }

    /// Get the embedding vector for a named voice.
    /// Falls back to the first embedding if the voice name is not found.
    private func getVoiceEmbedding(voice: String) -> [Float]? {
        // If we have a pre-parsed embedding for this voice, use it
        if let embedding = voiceEmbeddings[voice], embedding.count == Self.voiceEmbeddingDim {
            return embedding
        }

        // Fall back to extracting from raw data
        guard let rawFloats = voiceEmbeddings["__raw_data__"], rawFloats.count >= Self.voiceEmbeddingDim else {
            return nil
        }

        // Use the first embedding as default (offset 0)
        let embedding = Array(rawFloats.prefix(Self.voiceEmbeddingDim))
        return embedding
    }

    // MARK: - Audio Generation

    /// Run ONNX inference to generate PCM float32 audio from text.
    private func generateAudio(text: String, voice: String) -> Data? {
#if canImport(OnnxRuntimeBindings) || canImport(onnxruntime)
        guard let session = self.session else {
            logError("LocalTTSService: No ONNX session available")
            return nil
        }

        // Convert text to phoneme token IDs
        let tokens = textToTokens(text)
        guard !tokens.isEmpty else {
            logError("LocalTTSService: No tokens generated from text")
            return nil
        }

        do {
            // Input: tokens as Int64 tensor [1, seq_len]
            let tokenCount = tokens.count
            let tokenData = NSMutableData(
                bytes: tokens.map { Int64($0) },
                length: tokenCount * MemoryLayout<Int64>.size
            )
            let tokenTensor = try ORTValue(
                tensorData: tokenData,
                elementType: .int64,
                shape: [1, NSNumber(value: tokenCount)]
            )

            // Style (voice embedding): Float32 tensor [1, 256]
            let voiceEmb = getVoiceEmbedding(voice: voice) ?? [Float](repeating: 0.0, count: Self.voiceEmbeddingDim)
            let styleData = NSMutableData(bytes: voiceEmb, length: voiceEmb.count * MemoryLayout<Float>.size)
            let styleTensor = try ORTValue(
                tensorData: styleData,
                elementType: .float,
                shape: [1, NSNumber(value: Self.voiceEmbeddingDim)]
            )

            // Speed: Float32 scalar
            var speed: Float = 1.0
            let speedData = NSMutableData(bytes: &speed, length: MemoryLayout<Float>.size)
            let speedTensor = try ORTValue(
                tensorData: speedData,
                elementType: .float,
                shape: [1] as [NSNumber]
            )

            // Run inference
            let outputs = try session.run(
                withInputs: [
                    "tokens": tokenTensor,
                    "style": styleTensor,
                    "speed": speedTensor,
                ],
                outputNames: Set(["audio"]),
                runOptions: nil
            )

            // Extract audio output
            guard let audioValue = outputs["audio"] else {
                logError("LocalTTSService: No audio output from model")
                return nil
            }

            let audioData = try audioValue.tensorData() as Data
            log("LocalTTSService: Generated \(audioData.count) bytes of audio (\(String(format: "%.1f", Double(audioData.count / MemoryLayout<Float>.size) / Double(Self.sampleRate)))s)")
            return audioData

        } catch {
            logError("LocalTTSService: ONNX inference error", error: error)
            return nil
        }
#else
        return nil
#endif
    }

    // MARK: - Text to Tokens (Phoneme Tokenization)

    /// Convert English text to a sequence of phoneme token IDs for the Kokoro model.
    /// This is a simplified tokenizer -- for production, integrate espeak-ng or a learned G2P model.
    private func textToTokens(_ text: String) -> [Int] {
        // Kokoro uses a character/phoneme-level vocabulary.
        // For MVP, we use a simple character-level mapping that covers basic English.
        // Token 0 is typically padding, token 1 is BOS, token 2 is EOS.
        var tokens: [Int] = [1] // BOS

        let normalized = text.lowercased()
        for char in normalized {
            if let tokenId = Self.charToToken[char] {
                tokens.append(tokenId)
            }
            // Skip unknown characters silently
        }

        tokens.append(2) // EOS
        return tokens
    }

    /// Basic character-to-token mapping for Kokoro.
    /// This covers ASCII letters, digits, punctuation, and whitespace.
    /// The actual Kokoro model uses IPA phonemes; a full implementation would
    /// run espeak-ng or a G2P model to convert text to IPA first.
    private static let charToToken: [Character: Int] = {
        var map: [Character: Int] = [:]
        // Space
        map[" "] = 3
        // Punctuation
        map[","] = 4
        map["."] = 5
        map["!"] = 6
        map["?"] = 7
        map["-"] = 8
        map[":"] = 9
        map[";"] = 10
        map["'"] = 11
        map["\""] = 12

        // Letters a-z starting at token 13
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for (i, ch) in letters.enumerated() {
            map[ch] = 13 + i
        }

        // Digits 0-9 starting at token 39
        let digits = "0123456789"
        for (i, ch) in digits.enumerated() {
            map[ch] = 39 + i
        }

        return map
    }()
}

// MARK: - Errors

enum LocalTTSError: Error, CustomStringConvertible {
    case onnxNotAvailable
    case modelNotLoaded
    case invalidDownloadURL(String)
    case downloadFailed(String, Int)

    var description: String {
        switch self {
        case .onnxNotAvailable:
            return "ONNX Runtime is not available"
        case .modelNotLoaded:
            return "TTS model is not loaded"
        case .invalidDownloadURL(let url):
            return "Invalid download URL: \(url)"
        case .downloadFailed(let file, let status):
            return "Failed to download \(file): HTTP \(status)"
        }
    }
}
