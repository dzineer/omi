import Foundation

/// Manages a local MLX Whisper FastAPI subprocess for on-device speech-to-text.
/// Only usable on Apple Silicon (arm64). Spawns a Python uvicorn server on
/// localhost:8787 with an OpenAI-compatible /v1/audio/transcriptions endpoint.
actor MLXWhisperServer {

    // MARK: - Singleton

    /// Shared instance — only one MLX Whisper server should run at a time
    static let shared = MLXWhisperServer()

    // MARK: - Types

    enum ServerError: LocalizedError {
        case notAppleSilicon
        case pythonNotFound
        case serverStartFailed(String)
        case serverNotReady
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAppleSilicon:
                return "MLX Whisper requires Apple Silicon (arm64)"
            case .pythonNotFound:
                return "Python3 not found -- install via Homebrew or system"
            case .serverStartFailed(let reason):
                return "MLX Whisper server failed to start: \(reason)"
            case .serverNotReady:
                return "MLX Whisper server is not responding"
            case .transcriptionFailed(let reason):
                return "MLX transcription failed: \(reason)"
            }
        }
    }

    enum ServerState {
        case stopped
        case starting
        case installingDependencies
        case downloadingModel
        case running
        case failed(Error)
    }

    // MARK: - Properties

    private let host = "127.0.0.1"
    private let port = 8787
    private let model = "mlx-community/whisper-large-v3-turbo"

    private var process: Process?
    private var state: ServerState = .stopped
    private var healthCheckTask: Task<Void, Never>?
    private var pythonPath: String?
    private var venvPath: URL?

    /// Callback for state changes (e.g., downloading model, ready, failed).
    var onStateChanged: ((ServerState) -> Void)?

    var baseURL: String {
        "http://\(host):\(port)"
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var currentState: ServerState {
        state
    }

    // MARK: - Lifecycle

    /// Start the MLX Whisper server. Finds Python, creates venv, installs deps, spawns uvicorn.
    func start() async throws {
        guard Self.isAppleSilicon() else {
            throw ServerError.notAppleSilicon
        }

        // If already running, just return
        if case .running = state {
            log("MLXWhisperServer: Already running")
            return
        }

        // Kill any stale process on our port before starting
        killStaleServer()

        guard case .stopped = state else {
            log("MLXWhisperServer: Already starting")
            return
        }

        updateState(.starting)

        // Find a suitable Python3 binary
        guard let python = findPython3() else {
            updateState(.failed(ServerError.pythonNotFound))
            throw ServerError.pythonNotFound
        }
        pythonPath = python
        log("MLXWhisperServer: Using Python at \(python)")

        // Set up venv and install dependencies
        let venv = try await setupVenv(python: python)
        venvPath = venv

        // Write server.py to a temp location
        let serverScript = try writeServerScript()

        // Spawn uvicorn
        try spawnServer(venvPython: venv.appendingPathComponent("bin/python3").path, serverScript: serverScript)

        // Wait for the server to become healthy
        try await waitForHealthy(timeoutSeconds: 120)

        // Start periodic health checks
        startHealthCheckLoop()
    }

    /// Stop the server and clean up.
    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        if let proc = process, proc.isRunning {
            proc.interrupt()
            // Give it a moment to exit gracefully
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak proc] in
                if let p = proc, p.isRunning {
                    p.terminate()
                }
            }
        }
        process = nil
        updateState(.stopped)
        log("MLXWhisperServer: Stopped")
    }

    /// Transcribe WAV audio data by sending it to the local server.
    /// Returns the transcript text, or nil if the result was empty/hallucination.
    func transcribe(wavData: Data, language: String = "en") async throws -> String? {
        guard isRunning else {
            throw ServerError.serverNotReady
        }

        let url = URL(string: "\(baseURL)/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        // Build multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            throw ServerError.transcriptionFailed("HTTP \(statusCode): \(responseBody)")
        }

        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return nil
        }
        return text
    }

    // MARK: - Static Helpers

    /// Check if running on Apple Silicon.
    static func isAppleSilicon() -> Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.contains("arm64")
    }

    /// Kill any stale process listening on port 8787
    private nonisolated func killStaleServer() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bash", "-c", "lsof -ti:8787 | xargs kill -9 2>/dev/null"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        log("MLXWhisperServer: Cleaned up stale processes on port 8787")
    }

    // MARK: - Private

    private func updateState(_ newState: ServerState) {
        state = newState
        let callback = onStateChanged
        let capturedState = newState
        Task { @MainActor in
            callback?(capturedState)
        }
    }

    /// Find a usable Python3 binary. Checks Homebrew, system, and PATH.
    private func findPython3() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try PATH via which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["python3"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = Pipe()

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // Fall through
        }

        return nil
    }

    /// Create a virtual environment and install MLX Whisper dependencies.
    private func setupVenv(python: String) async throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let venvDir = appSupport.appendingPathComponent("VoiceAI/mlx-whisper-venv")

        let venvPython = venvDir.appendingPathComponent("bin/python3")

        // Check if venv already exists with the right packages
        if FileManager.default.fileExists(atPath: venvPython.path) {
            let checkResult = try runProcess(
                executable: venvPython.path,
                arguments: ["-c", "import mlx_whisper, fastapi, uvicorn; print('ok')"]
            )
            if checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                log("MLXWhisperServer: Existing venv is valid")
                return venvDir
            }
        }

        updateState(.installingDependencies)
        log("MLXWhisperServer: Creating venv at \(venvDir.path)")

        // Create venv
        try FileManager.default.createDirectory(at: venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try runProcess(executable: python, arguments: ["-m", "venv", venvDir.path])

        // Install dependencies
        log("MLXWhisperServer: Installing mlx-whisper, fastapi, uvicorn...")
        _ = try runProcess(
            executable: venvPython.path,
            arguments: ["-m", "pip", "install", "--quiet", "mlx-whisper", "fastapi", "uvicorn[standard]", "python-multipart"]
        )

        log("MLXWhisperServer: Dependencies installed")
        return venvDir
    }

    /// Write the server.py script to a temp directory.
    private func writeServerScript() throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scriptDir = appSupport.appendingPathComponent("VoiceAI")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let scriptPath = scriptDir.appendingPathComponent("mlx_whisper_server.py")

        let script = """
        import os, tempfile
        from pathlib import Path
        import mlx_whisper
        from fastapi import FastAPI, File, Form, UploadFile
        from fastapi.responses import JSONResponse, PlainTextResponse

        app = FastAPI(title="MLX Whisper Server", version="0.1.0")
        DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

        @app.get("/health")
        async def health():
            return {"status": "ok", "model": DEFAULT_MODEL}

        @app.post("/v1/audio/transcriptions")
        async def transcribe(
            file: UploadFile = File(...),
            model: str = Form(DEFAULT_MODEL),
            response_format: str = Form("text"),
            language: str = Form("en"),
        ):
            suffix = Path(file.filename).suffix if file.filename else ".wav"
            with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
                content = await file.read()
                tmp.write(content)
                tmp_path = tmp.name
            try:
                # "multi" means auto-detect — pass None to mlx_whisper
                lang = None if language in ("multi", "auto", "") else language
                result = mlx_whisper.transcribe(
                    tmp_path, path_or_hf_repo=model, language=lang,
                )
                text = result.get("text", "").strip()
                if response_format == "json":
                    return JSONResponse(content={
                        "text": text,
                        "segments": result.get("segments", []),
                        "language": result.get("language", language),
                    })
                else:
                    return PlainTextResponse(content=text)
            finally:
                os.unlink(tmp_path)

        if __name__ == "__main__":
            import uvicorn
            uvicorn.run(app, host="127.0.0.1", port=\(port))
        """

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        return scriptPath.path
    }

    /// Spawn the uvicorn process.
    private func spawnServer(venvPython: String, serverScript: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [serverScript]
        proc.environment = ProcessInfo.processInfo.environment

        // Capture stdout/stderr for logging
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        // Log output asynchronously
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                log("MLXWhisperServer [stdout]: \(line.trimmingCharacters(in: .newlines))")
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                log("MLXWhisperServer [stderr]: \(line.trimmingCharacters(in: .newlines))")
            }
        }

        proc.terminationHandler = { [weak self] terminatedProcess in
            let code = terminatedProcess.terminationStatus
            log("MLXWhisperServer: Process exited with code \(code)")
            Task { [weak self] in
                await self?.handleProcessExit(code: code)
            }
        }

        do {
            try proc.run()
            process = proc
            log("MLXWhisperServer: Spawned server (PID \(proc.processIdentifier))")
        } catch {
            throw ServerError.serverStartFailed(error.localizedDescription)
        }
    }

    /// Wait for the /health endpoint to respond, with timeout.
    private func waitForHealthy(timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let healthURL = URL(string: "\(baseURL)/health")!

        while Date() < deadline {
            do {
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    log("MLXWhisperServer: Health check passed: \(body)")
                    updateState(.running)
                    return
                }
            } catch {
                // Server not ready yet -- keep waiting
            }

            // Check if the process died
            if let proc = process, !proc.isRunning {
                throw ServerError.serverStartFailed("Process exited with code \(proc.terminationStatus)")
            }

            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        }

        throw ServerError.serverStartFailed("Timed out waiting for server to become healthy")
    }

    /// Periodic health check. Restarts server if it goes down.
    private func startHealthCheckLoop() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                guard !Task.isCancelled else { break }
                await self?.performHealthCheck()
            }
        }
    }

    private func performHealthCheck() {
        guard isRunning else { return }

        let healthURL = URL(string: "\(baseURL)/health")!
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                log("MLXWhisperServer: Health check failed: \(error.localizedDescription)")
                Task { await self?.handleHealthFailure() }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                log("MLXWhisperServer: Health check returned non-200")
                Task { await self?.handleHealthFailure() }
                return
            }
        }
        task.resume()
    }

    private func handleHealthFailure() {
        log("MLXWhisperServer: Attempting restart after health check failure")
        stop()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                try await start()
            } catch {
                logError("MLXWhisperServer: Restart failed", error: error)
            }
        }
    }

    private func handleProcessExit(code: Int32) {
        guard isRunning else { return }
        log("MLXWhisperServer: Unexpected exit (code \(code)), will restart")
        updateState(.failed(ServerError.serverStartFailed("Unexpected exit: \(code)")))
        process = nil

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                updateState(.stopped)
                try await start()
            } catch {
                logError("MLXWhisperServer: Auto-restart failed", error: error)
            }
        }
    }

    /// Run a process synchronously and return stdout.
    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            throw ServerError.serverStartFailed("Process \(executable) exited with \(proc.terminationStatus): \(errOutput)")
        }

        return output
    }

    deinit {
        // Note: deinit on actors is non-isolated, so we can only do synchronous cleanup
        healthCheckTask?.cancel()
        if let proc = process, proc.isRunning {
            proc.interrupt()
        }
    }
}
