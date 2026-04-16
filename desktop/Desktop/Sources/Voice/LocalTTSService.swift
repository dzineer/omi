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
        // Find Python (reuses MLX Whisper venv, which the app auto-provisions)
        let pythonPath = findPython()
        guard let python = pythonPath else {
            logError("LocalTTSService: Python not found")
            return
        }

        // Auto-install kokoro-onnx into the venv if missing.
        await ensureKokoroInstalled(venvPython: python)

        // Auto-download Kokoro model + voices if missing.
        await ensureKokoroAssets()

        // Auto-write the server script to disk if missing.
        let scriptPath: String
        do {
            scriptPath = try writeServerScript()
        } catch {
            logError("LocalTTSService: Failed to write server script", error: error)
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

    // MARK: - Dependency & Asset Provisioning

    /// Install kokoro-onnx into the shared venv if it isn't already installed.
    private func ensureKokoroInstalled(venvPython: String) async {
        // Only auto-install when running from the shared venv (not system python).
        guard venvPython.contains("mlx-whisper-venv") else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: venvPython)
        check.arguments = ["-c", "import kokoro_onnx"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run()
            check.waitUntilExit()
            if check.terminationStatus == 0 { return }  // Already installed
        } catch { return }

        log("LocalTTSService: Installing kokoro-onnx into venv")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: venvPython)
        install.arguments = ["-m", "pip", "install", "--quiet", "kokoro-onnx"]
        install.standardOutput = FileHandle.nullDevice
        install.standardError = FileHandle.nullDevice
        do {
            try install.run()
            install.waitUntilExit()
            if install.terminationStatus == 0 {
                log("LocalTTSService: kokoro-onnx installed")
            } else {
                logError("LocalTTSService: kokoro-onnx install failed (exit \(install.terminationStatus))")
            }
        } catch {
            logError("LocalTTSService: Failed to run pip install", error: error)
        }
    }

    /// Download Kokoro model + voices on first run if they aren't cached on disk.
    private func ensureKokoroAssets() async {
        let home = NSHomeDirectory()
        let ttsDir = home + "/Library/Application Support/VoiceTTS"
        try? FileManager.default.createDirectory(atPath: ttsDir, withIntermediateDirectories: true)

        let assets: [(name: String, url: String)] = [
            ("kokoro-v1.0.onnx", "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"),
            ("voices-v1.0.bin", "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"),
        ]
        for asset in assets {
            let path = "\(ttsDir)/\(asset.name)"
            if FileManager.default.fileExists(atPath: path) { continue }
            log("LocalTTSService: Downloading \(asset.name) from GitHub releases")
            guard let url = URL(string: asset.url) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: URL(fileURLWithPath: path))
                log("LocalTTSService: Wrote \(asset.name) (\(data.count) bytes)")
            } catch {
                logError("LocalTTSService: Failed to download \(asset.name)", error: error)
            }
        }
    }

    /// Write the Kokoro server script to disk, creating the directory if needed.
    private func writeServerScript() throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scriptDir = appSupport.appendingPathComponent("VoiceAI")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let scriptPath = scriptDir.appendingPathComponent("kokoro_tts_server.py")

        let script = #"""
        """Kokoro TTS server — FastAPI endpoint for text-to-speech."""
        from fastapi import FastAPI, Form
        from fastapi.responses import Response
        from kokoro_onnx import Kokoro
        import numpy as np
        import os, io, wave

        MODEL_PATH = os.path.expanduser("~/Library/Application Support/VoiceTTS/kokoro-v1.0.onnx")
        VOICES_PATH = os.path.expanduser("~/Library/Application Support/VoiceTTS/voices-v1.0.bin")

        app = FastAPI()
        kokoro = None

        @app.on_event("startup")
        async def load_model():
            global kokoro
            kokoro = Kokoro(MODEL_PATH, VOICES_PATH)

        @app.get("/health")
        async def health():
            return {"status": "ok", "model": "kokoro-v1.0"}

        @app.post("/v1/audio/speech")
        async def speak(
            text: str = Form(...),
            voice: str = Form("af_heart"),
            speed: float = Form(1.0),
        ):
            samples, sr = kokoro.create(text, voice=voice, speed=speed)
            audio_16bit = np.clip(samples * 32767, -32768, 32767).astype(np.int16)
            buf = io.BytesIO()
            with wave.open(buf, "w") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(sr)
                w.writeframes(audio_16bit.tobytes())
            return Response(content=buf.getvalue(), media_type="audio/wav")

        if __name__ == "__main__":
            import uvicorn
            port = int(os.environ.get("PORT", "8788"))
            uvicorn.run(app, host="127.0.0.1", port=port)
        """#

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        return scriptPath.path
    }
}
