import Foundation
import AVFoundation

/// On-device text-to-speech using Kokoro via a local Python server on port 8788.
/// The server handles phoneme tokenization and ONNX inference.
/// Audio is returned as WAV and played via AVAudioEngine.
actor LocalTTSService {

    // MARK: - Public Properties

    var isSpeaking: Bool {
        return player.isPlaying
    }

    nonisolated var onSpeechStarted: (() -> Void)? {
        get { player.onPlaybackStarted }
        set { player.onPlaybackStarted = newValue }
    }

    nonisolated var onSpeechFinished: (() -> Void)? {
        get { player.onPlaybackFinished }
        set { player.onPlaybackFinished = newValue }
    }

    // MARK: - Constants

    private static let serverPort = 8788
    private static let baseURL = "http://127.0.0.1:8788"
    private static let defaultVoice = "af_heart"

    // MARK: - Private Properties

    nonisolated(unsafe) private let player = TTSAudioPlayer()
    private var serverProcess: Process?
    private var isServerRunning = false

    // MARK: - Public Methods

    func speak(_ text: String) async {
        await speak(text, voice: Self.defaultVoice)
    }

    func speak(_ text: String, voice: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ensure Kokoro server is running
        await ensureServerRunning()

        // Call the Kokoro TTS server
        guard let wavData = await generateSpeech(text: trimmed, voice: voice) else {
            logError("LocalTTSService: Failed to generate speech")
            return
        }

        // Play the WAV audio
        player.play(wavData, sampleRate: 24000)
        log("LocalTTSService: Playing Kokoro audio (\(wavData.count) bytes)")
    }

    nonisolated func stop() {
        player.stop()
    }

    func shutdown() async {
        player.stop()
        serverProcess?.terminate()
        serverProcess = nil
        isServerRunning = false
        log("LocalTTSService: Shut down")
    }

    // MARK: - Server Management

    private func ensureServerRunning() async {
        if isServerRunning {
            // Quick health check
            if await checkHealth() { return }
            isServerRunning = false
        }

        await startServer()
    }

    private func startServer() async {
        // Find Python
        let pythonPath = findPython()
        guard let python = pythonPath else {
            logError("LocalTTSService: Python not found")
            return
        }

        let scriptPath = NSHomeDirectory() + "/Library/Application Support/VoiceAI/kokoro_tts_server.py"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logError("LocalTTSService: kokoro_tts_server.py not found at \(scriptPath)")
            return
        }

        // Kill any stale process on our port
        let killProc = Process()
        killProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        killProc.arguments = ["bash", "-c", "lsof -ti:8788 | xargs kill -9 2>/dev/null"]
        killProc.standardOutput = FileHandle.nullDevice
        killProc.standardError = FileHandle.nullDevice
        try? killProc.run()
        killProc.waitUntilExit()

        // Start server
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [scriptPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        serverProcess = proc

        do {
            try proc.run()
            log("LocalTTSService: Started Kokoro TTS server (PID \(proc.processIdentifier))")

            // Wait for server to be ready
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await checkHealth() {
                    isServerRunning = true
                    log("LocalTTSService: Kokoro TTS server ready")
                    return
                }
            }
            logError("LocalTTSService: Kokoro TTS server failed to start in time")
        } catch {
            logError("LocalTTSService: Failed to start Kokoro server", error: error)
        }
    }

    private func checkHealth() async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Speech Generation

    private func generateSpeech(text: String, voice: String) async -> Data? {
        guard let url = URL(string: "\(Self.baseURL)/v1/audio/speech") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // text field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"text\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(text)\r\n".data(using: .utf8)!)
        // voice field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"voice\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(voice)\r\n".data(using: .utf8)!)
        // speed field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"speed\"\r\n\r\n".data(using: .utf8)!)
        body.append("1.0\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logError("LocalTTSService: TTS server returned \(code)")
                return nil
            }

            // The response is a WAV file — extract raw PCM (skip 44-byte header)
            guard data.count > 44 else {
                logError("LocalTTSService: WAV too small (\(data.count) bytes)")
                return nil
            }

            // Return the raw PCM data (skip WAV header) as float32
            let pcmData = data.subdata(in: 44..<data.count)
            // Convert 16-bit PCM to float32 for AVAudioEngine
            let sampleCount = pcmData.count / 2
            var floatData = Data(capacity: sampleCount * 4)
            pcmData.withUnsafeBytes { rawBuffer in
                let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    var sample = Float(int16Ptr[i]) / 32768.0
                    withUnsafeBytes(of: &sample) { floatData.append(contentsOf: $0) }
                }
            }

            log("LocalTTSService: Generated \(floatData.count) bytes (\(String(format: "%.1f", Float(sampleCount) / 24000.0))s)")
            return floatData
        } catch {
            logError("LocalTTSService: Speech generation failed", error: error)
            return nil
        }
    }

    // MARK: - Python Discovery

    private func findPython() -> String? {
        // Check venv first (same one MLX Whisper uses)
        let venvPython = NSHomeDirectory() + "/Library/Application Support/VoiceAI/mlx-whisper-venv/bin/python3"
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return venvPython
        }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
