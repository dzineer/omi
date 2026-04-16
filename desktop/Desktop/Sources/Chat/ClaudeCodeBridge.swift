import Foundation

/// Drop-in replacement for ACPBridge that spawns Claude Code CLI directly
/// using `claude -p --output-format stream-json --input-format stream-json`.
///
/// This eliminates the Node.js ACP Bridge middleman and gives access to
/// Claude Code's full 40+ tool suite, MCP integration, permission system,
/// session persistence, and context compression.
///
/// Communication uses NDJSON (newline-delimited JSON) over stdin/stdout pipes.
actor ClaudeCodeBridge: ChatBridge {

  // MARK: - Types (from ChatBridgeProtocol)

  typealias TextDeltaHandler = @Sendable (String) -> Void
  typealias ToolCallHandler = @Sendable (String, String, [String: Any]) async -> String
  typealias ToolActivityHandler = @Sendable (String, String, String?, [String: Any]?) -> Void
  typealias ThinkingDeltaHandler = @Sendable (String) -> Void
  typealias ToolResultDisplayHandler = @Sendable (String, String, String) -> Void
  typealias AuthRequiredHandler = @Sendable ([[String: Any]], String?) -> Void
  typealias AuthSuccessHandler = @Sendable () -> Void

  /// Internal message types parsed from Claude Code's NDJSON stdout
  private enum InboundMessage {
    case systemInit(sessionId: String, model: String?)
    case textDelta(text: String)
    case thinkingDelta(text: String)
    case toolUseStart(toolUseId: String, name: String, input: [String: Any])
    case toolProgress(toolUseId: String, name: String, elapsed: Double?)
    case toolResult(toolUseId: String, name: String, output: String)
    case permissionRequest(requestId: String, toolName: String, input: [String: Any], toolUseId: String?)
    case result(
      text: String, sessionId: String, costUsd: Double,
      inputTokens: Int, outputTokens: Int,
      cacheReadTokens: Int, cacheWriteTokens: Int)
    case error(message: String)
    case authStatus(isAuthenticating: Bool, output: [String]?)
    case ignored
  }

  // MARK: - Configuration

  let passApiKey: Bool

  var onAuthRequiredGlobal: AuthRequiredHandler?
  var onAuthSuccessGlobal: AuthSuccessHandler?

  func setGlobalAuthHandlers(
    onAuthRequired: AuthRequiredHandler?,
    onAuthSuccess: AuthSuccessHandler?
  ) {
    self.onAuthRequiredGlobal = onAuthRequired
    self.onAuthSuccessGlobal = onAuthSuccess
  }

  init(passApiKey: Bool = false) {
    self.passApiKey = passApiKey
  }

  // MARK: - State

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var isRunning = false
  private var readTask: Task<Void, Never>?
  private var processGeneration: UInt64 = 0

  private var pendingMessages: [InboundMessage] = []
  private var messageContinuation: CheckedContinuation<InboundMessage, Error>?
  private var messageGeneration: UInt64 = 0
  private var isInterrupted = false

  /// Current session ID for multi-turn conversations
  private var currentSessionId: String?
  /// Cached claude binary path
  private var claudeBinaryPath: String?

  /// MCP config file path (temp file, cleaned up on stop)
  private var mcpConfigPath: String?

  /// Unix socket path for vibeai-tools relay
  private var bridgePipePath: String?

  var isAlive: Bool { isRunning }

  // MARK: - Lifecycle

  func start() async throws {
    guard !isRunning else { return }

    readTask?.cancel()
    readTask = nil
    process = nil
    closePipes()
    pendingMessages.removeAll()
    messageContinuation = nil
    isInterrupted = false

    let claudePath = findClaudeBinary()
    guard let claudePath else {
      throw BridgeError.nodeNotFound  // Reuse existing error type for compatibility
    }
    self.claudeBinaryPath = claudePath

    log("ClaudeCodeBridge: found claude binary at \(claudePath)")

    // Bridge is ready — actual subprocess is spawned per-query in stream-json mode
    isRunning = true
  }

  func restart() async throws {
    stop()
    try await start()
  }

  func stop() {
    log("ClaudeCodeBridge: stopping")
    readTask?.cancel()
    readTask = nil

    // Send interrupt via stdin if process is alive
    if let process = process, process.isRunning {
      process.interrupt()  // SIGINT for graceful shutdown
    }

    process?.terminate()
    process = nil
    closePipes()
    isRunning = false
    currentSessionId = nil

    // Clean up temp MCP config
    if let path = mcpConfigPath {
      try? FileManager.default.removeItem(atPath: path)
      mcpConfigPath = nil
    }

    messageContinuation?.resume(throwing: BridgeError.stopped)
    messageContinuation = nil
  }

  // MARK: - Session Pre-warming

  func warmupSession(cwd: String? = nil, sessions: [WarmupSessionConfig]) {
    // Claude Code manages sessions internally via --session-id / --resume.
    // No explicit warmup needed — sessions are persisted to ~/.claude/sessions/.
    // We just store the config for use in query().
    log("ClaudeCodeBridge: warmup requested for \(sessions.count) session(s) — sessions managed by Claude Code natively")
  }

  // MARK: - Query

  func query(
    prompt: String,
    systemPrompt: String,
    sessionKey: String? = nil,
    cwd: String? = nil,
    mode: String? = nil,
    model: String? = nil,
    resume: String? = nil,
    imageData: Data? = nil,
    onTextDelta: @escaping TextDeltaHandler,
    onToolCall: @escaping ToolCallHandler,
    onToolActivity: @escaping ToolActivityHandler,
    onThinkingDelta: @escaping ThinkingDeltaHandler = { _ in },
    onToolResultDisplay: @escaping ToolResultDisplayHandler = { _, _, _ in },
    onAuthRequired: @escaping AuthRequiredHandler = { _, _ in },
    onAuthSuccess: @escaping AuthSuccessHandler = {}
  ) async throws -> ChatBridgeQueryResult {
    guard isRunning else {
      throw BridgeError.notRunning
    }
    guard let claudePath = claudeBinaryPath else {
      throw BridgeError.nodeNotFound
    }

    isInterrupted = false
    pendingMessages.removeAll()

    // Build command arguments
    var args = buildArgs(
      prompt: prompt,
      systemPrompt: systemPrompt,
      sessionKey: sessionKey,
      cwd: cwd,
      mode: mode,
      model: model,
      resume: resume
    )

    // Set up MCP servers
    let effectiveCwd = cwd ?? FileManager.default.currentDirectoryPath
    let effectiveMode = mode ?? "act"
    setupMCPConfig(nodePath: findNodeBinary(), cwd: effectiveCwd, mode: effectiveMode)
    if let configPath = mcpConfigPath {
      args.append(contentsOf: ["--mcp-config", configPath])
    }

    // Spawn the claude process
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: claudePath)
    proc.arguments = args

    // Build environment
    var env = ProcessInfo.processInfo.environment
    if !passApiKey {
      env.removeValue(forKey: "ANTHROPIC_API_KEY")
    }
    env.removeValue(forKey: "CLAUDE_CODE_USE_VERTEX")

    // Ensure claude binary dir is in PATH
    let claudeDir = (claudePath as NSString).deletingLastPathComponent
    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
    if !existingPath.contains(claudeDir) {
      env["PATH"] = "\(claudeDir):\(existingPath)"
    }

    if let cwd = cwd {
      proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    proc.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()

    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = stderr

    self.stdinPipe = stdin
    self.stdoutPipe = stdout
    self.stderrPipe = stderr
    self.process = proc

    // Read stderr for logging
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
        log("ClaudeCodeBridge stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
    }

    processGeneration &+= 1
    let expectedGeneration = processGeneration

    proc.terminationHandler = { [weak self] terminatedProc in
      let code = terminatedProc.terminationStatus
      let reason = terminatedProc.terminationReason
      Task { [weak self] in
        await self?.handleTermination(exitCode: code, reason: reason, generation: expectedGeneration)
      }
    }

    try proc.run()
    startReadingStdout()

    log("ClaudeCodeBridge: spawned claude process (pid=\(proc.processIdentifier))")

    // Accumulate the full response text
    var fullText = ""
    var resultSessionId = currentSessionId ?? ""
    var resultCost: Double = 0
    var resultInputTokens = 0
    var resultOutputTokens = 0
    var resultCacheRead = 0
    var resultCacheWrite = 0

    // Track active tool uses for activity callbacks
    var activeToolUses: Set<String> = []

    // Read messages until result or process exit
    while true {
      let message: InboundMessage
      do {
        message = try await waitForMessage()
      } catch {
        // Process exited — return what we have
        if !fullText.isEmpty {
          return ChatBridgeQueryResult(
            text: fullText, costUsd: resultCost, sessionId: resultSessionId,
            inputTokens: resultInputTokens, outputTokens: resultOutputTokens,
            cacheReadTokens: resultCacheRead, cacheWriteTokens: resultCacheWrite)
        }
        throw error
      }

      switch message {
      case .systemInit(let sessionId, _):
        resultSessionId = sessionId
        currentSessionId = sessionId
        log("ClaudeCodeBridge: session initialized (\(sessionId))")

      case .textDelta(let text):
        fullText += text
        onTextDelta(text)

      case .thinkingDelta(let text):
        onThinkingDelta(text)

      case .toolUseStart(let toolUseId, let name, let input):
        if isInterrupted { continue }
        activeToolUses.insert(toolUseId)
        onToolActivity(name, "started", toolUseId, input)

      case .toolProgress(let toolUseId, let name, _):
        if isInterrupted { continue }
        // Tool is still running — no callback needed, just log
        log("ClaudeCodeBridge: tool progress \(name) (\(toolUseId))")

      case .toolResult(let toolUseId, let name, let output):
        activeToolUses.remove(toolUseId)
        onToolActivity(name, "completed", toolUseId, nil)
        onToolResultDisplay(toolUseId, name, String(output.prefix(2000)))

      case .permissionRequest(let requestId, let toolName, let input, let toolUseId):
        if isInterrupted {
          // Auto-deny when interrupted
          sendControlResponse(requestId: requestId, approved: false)
          continue
        }
        // Execute tool via Swift callback (for vibeai-tools/local tools)
        // or auto-approve Claude Code's built-in tools
        let callId = toolUseId ?? requestId
        if isVibeAiLocalTool(toolName) {
          // Route to Swift-side execution
          let toolResult = await onToolCall(callId, toolName, input)
          sendControlResponse(requestId: requestId, approved: true, result: toolResult)
        } else {
          // Auto-approve Claude Code built-in tools
          sendControlResponse(requestId: requestId, approved: true)
        }

      case .result(let text, let sessionId, let costUsd, let inputTokens, let outputTokens,
        let cacheRead, let cacheWrite):
        if !text.isEmpty { fullText = text }
        resultSessionId = sessionId
        resultCost = costUsd
        resultInputTokens = inputTokens
        resultOutputTokens = outputTokens
        resultCacheRead = cacheRead
        resultCacheWrite = cacheWrite
        currentSessionId = sessionId

        return ChatBridgeQueryResult(
          text: fullText, costUsd: resultCost, sessionId: resultSessionId,
          inputTokens: resultInputTokens, outputTokens: resultOutputTokens,
          cacheReadTokens: resultCacheRead, cacheWriteTokens: resultCacheWrite)

      case .error(let msg):
        log("ClaudeCodeBridge: error: \(msg)")
        throw BridgeError.agentError(msg)

      case .authStatus(let isAuth, let output):
        if isAuth {
          onAuthRequired([], output?.first)
        } else {
          onAuthSuccess()
        }

      case .ignored:
        continue
      }
    }
  }

  // MARK: - Interruption

  func interrupt() {
    guard isRunning else { return }
    isInterrupted = true
    // Send SIGINT to claude process for graceful interruption
    if let proc = process, proc.isRunning {
      proc.interrupt()
    }
  }

  // MARK: - Authentication (compatibility)

  func authenticate(methodId: String) {
    // Claude Code handles auth internally via its OAuth flow
    log("ClaudeCodeBridge: authenticate called (methodId=\(methodId)) — handled by Claude Code")
  }

  // MARK: - Playwright Connection Test

  func testPlaywrightConnection() async throws -> Bool {
    guard isRunning else { throw BridgeError.notRunning }
    log("ClaudeCodeBridge: Testing Playwright connection...")
    let result = try await query(
      prompt: "Call browser_snapshot to verify the extension is connected. Only call that one tool, then report success or failure.",
      systemPrompt: "You are a connection test agent. Call the browser_snapshot tool exactly once. If it succeeds, respond with exactly 'CONNECTED'. If it fails, respond with 'FAILED' followed by the error.",
      mode: "ask",
      onTextDelta: { _ in },
      onToolCall: { _, _, _ in "" },
      onToolActivity: { name, status, _, _ in
        log("ClaudeCodeBridge: test tool activity: \(name) \(status)")
      },
      onThinkingDelta: { _ in },
      onToolResultDisplay: { _, name, output in
        log("ClaudeCodeBridge: test tool result: \(name) -> \(output.prefix(200))")
      }
    )
    let connected = result.text.contains("CONNECTED")
    log("ClaudeCodeBridge: Playwright test: \(result.text.prefix(300)), connected=\(connected)")
    return connected
  }

  // MARK: - Private: Build CLI Arguments

  private func buildArgs(
    prompt: String,
    systemPrompt: String,
    sessionKey: String?,
    cwd: String?,
    mode: String?,
    model: String?,
    resume: String?
  ) -> [String] {
    var args: [String] = []

    // The prompt itself
    args.append(prompt)

    // Non-interactive print mode with streaming JSON
    args.append("-p")
    args.append("--output-format")
    args.append("stream-json")

    // Include partial messages for real-time streaming
    args.append("--include-partial-messages")

    // System prompt
    if !systemPrompt.isEmpty {
      args.append("--system-prompt")
      args.append(systemPrompt)
    }

    // Model selection
    if let model = model, !model.isEmpty {
      args.append("--model")
      args.append(model)
    }

    // Session management
    if let resume = resume, !resume.isEmpty {
      args.append("--resume")
      args.append(resume)
    } else if let sessionId = currentSessionId, !sessionId.isEmpty {
      args.append("--session-id")
      args.append(sessionId)
    }

    // Permission mode: auto-approve for seamless chat experience
    // Claude Code's built-in tools are trusted; Omi-specific tools go through onToolCall
    args.append("--permission-mode")
    args.append("bypassPermissions")

    // Thinking mode
    args.append("--thinking")
    args.append("enabled")

    // Cost safety
    args.append("--max-budget-usd")
    args.append("5.0")

    return args
  }

  // MARK: - Private: MCP Configuration

  private func setupMCPConfig(nodePath: String?, cwd: String, mode: String) {
    // Clean up previous config
    if let path = mcpConfigPath {
      try? FileManager.default.removeItem(atPath: path)
      mcpConfigPath = nil
    }

    guard let node = nodePath else { return }

    // Set up Unix socket for vibeai-tools relay
    let pipePath = NSTemporaryDirectory() + "claude-code-bridge-\(ProcessInfo.processInfo.processIdentifier).sock"
    bridgePipePath = pipePath

    // No Playwright — we don't use browser automation
    let servers = ClaudeCodeMCPConfig.defaultServers(
      nodePath: node,
      bridgePipePath: pipePath,
      cwd: cwd,
      mode: mode,
      includePlaywright: false,
      playwrightToken: nil
    )

    if !servers.isEmpty {
      mcpConfigPath = ClaudeCodeMCPConfig.writeConfigFile(servers: servers)
    }
  }

  // MARK: - Private: Message Parsing

  private func startReadingStdout() {
    guard let stdout = stdoutPipe else { return }

    readTask = Task.detached { [weak self] in
      let handle = stdout.fileHandleForReading
      var buffer = Data()

      while !Task.isCancelled {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = buffer[buffer.startIndex..<newlineIndex]
          buffer = Data(buffer[buffer.index(after: newlineIndex)...])

          guard let lineStr = String(data: lineData, encoding: .utf8),
            !lineStr.trimmingCharacters(in: .whitespaces).isEmpty
          else { continue }

          if let message = Self.parseMessage(lineStr) {
            await self?.deliverMessage(message)
          }
        }
      }
    }
  }

  private static func parseMessage(_ json: String) -> InboundMessage? {
    guard let data = json.data(using: .utf8) else {
      log("ClaudeCodeBridge: failed to decode JSON line")
      return nil
    }

    let decoder = JSONDecoder()
    guard let msg = try? decoder.decode(ClaudeCodeMessage.self, from: data) else {
      log("ClaudeCodeBridge: failed to parse message: \(json.prefix(200))")
      return nil
    }

    switch msg.type {
    case "system":
      return parseSystemMessage(msg)

    case "assistant":
      return parseAssistantMessage(msg)

    case "stream_event":
      return parseStreamEvent(msg)

    case "result":
      return parseResultMessage(msg)

    case "control_request":
      return parseControlRequest(msg)

    case "tool_progress":
      let toolUseId = msg.tool_use_id ?? ""
      let name = msg.tool_name ?? ""
      return .toolProgress(toolUseId: toolUseId, name: name, elapsed: msg.elapsed_time_seconds)

    case "auth_status":
      return .authStatus(isAuthenticating: msg.isAuthenticating ?? false, output: msg.output)

    default:
      // Log unknown types but don't crash
      log("ClaudeCodeBridge: ignoring message type: \(msg.type)")
      return .ignored
    }
  }

  private static func parseSystemMessage(_ msg: ClaudeCodeMessage) -> InboundMessage {
    guard let subtype = msg.subtype else { return .ignored }

    switch subtype {
    case "init":
      let sessionId = msg.session_id ?? ""
      return .systemInit(sessionId: sessionId, model: msg.model)

    case "status":
      log("ClaudeCodeBridge: status: \(msg.status ?? "unknown")")
      return .ignored

    case "api_retry":
      log("ClaudeCodeBridge: API retry")
      return .ignored

    default:
      return .ignored
    }
  }

  private static func parseAssistantMessage(_ msg: ClaudeCodeMessage) -> InboundMessage {
    guard let body = msg.message, let content = body.content else {
      return .ignored
    }

    // Process content blocks
    for block in content {
      switch block.type {
      case "text":
        if let text = block.text, !text.isEmpty {
          return .textDelta(text: text)
        }

      case "thinking":
        if let thinking = block.thinking, !thinking.isEmpty {
          return .thinkingDelta(text: thinking)
        }

      case "tool_use":
        let id = block.id ?? ""
        let name = block.name ?? ""
        let input = block.input?.dictValue ?? [:]
        return .toolUseStart(toolUseId: id, name: name, input: input)

      case "tool_result":
        let toolUseId = block.tool_use_id ?? ""
        let output: String
        if let contentAny = block.content {
          if let str = contentAny.stringValue {
            output = str
          } else if let arr = contentAny.arrayValue as? [[String: Any]] {
            // Array of content blocks — extract text
            output = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
          } else {
            output = String(describing: contentAny.value)
          }
        } else {
          output = ""
        }
        return .toolResult(toolUseId: toolUseId, name: "", output: output)

      default:
        continue
      }
    }
    return .ignored
  }

  private static func parseStreamEvent(_ msg: ClaudeCodeMessage) -> InboundMessage {
    guard let event = msg.event, let delta = event.delta else {
      // Check for content_block_start (tool_use start)
      if let event = msg.event, event.type == "content_block_start",
        let block = event.content_block
      {
        if block.type == "tool_use" {
          let id = block.id ?? ""
          let name = block.name ?? ""
          return .toolUseStart(toolUseId: id, name: name, input: [:])
        }
        if block.type == "thinking" {
          return .ignored  // Will get thinking deltas
        }
      }
      return .ignored
    }

    switch delta.type {
    case "text_delta":
      if let text = delta.text, !text.isEmpty {
        return .textDelta(text: text)
      }

    case "thinking_delta":
      if let thinking = delta.thinking, !thinking.isEmpty {
        return .thinkingDelta(text: thinking)
      }

    case "input_json_delta":
      // Partial tool input — ignore, wait for full tool_use in assistant message
      break

    default:
      break
    }
    return .ignored
  }

  private static func parseResultMessage(_ msg: ClaudeCodeMessage) -> InboundMessage {
    let sessionId = msg.session_id ?? ""
    let costUsd = msg.total_cost_usd ?? 0

    let inputTokens = msg.usage?.input_tokens ?? 0
    let outputTokens = msg.usage?.output_tokens ?? 0
    let cacheRead = msg.usage?.cache_read_input_tokens ?? 0
    let cacheWrite = msg.usage?.cache_creation_input_tokens ?? 0

    // Extract result text
    let resultText: String
    if let r = msg.result {
      if let str = r.stringValue {
        resultText = str
      } else {
        resultText = ""
      }
    } else {
      resultText = ""
    }

    if msg.is_error == true {
      let errorMsg = msg.errors?.joined(separator: "; ") ?? resultText
      if !errorMsg.isEmpty {
        return .error(message: errorMsg)
      }
    }

    return .result(
      text: resultText, sessionId: sessionId, costUsd: costUsd,
      inputTokens: inputTokens, outputTokens: outputTokens,
      cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite)
  }

  private static func parseControlRequest(_ msg: ClaudeCodeMessage) -> InboundMessage {
    guard let request = msg.request else { return .ignored }

    switch request.subtype {
    case "can_use_tool":
      let requestId = msg.request_id ?? ""
      let toolName = request.tool_name ?? ""
      let input = request.input?.dictValue ?? [:]
      let toolUseId = request.tool_use_id
      return .permissionRequest(requestId: requestId, toolName: toolName, input: input, toolUseId: toolUseId)

    default:
      log("ClaudeCodeBridge: ignoring control request subtype: \(request.subtype ?? "nil")")
      return .ignored
    }
  }

  // MARK: - Private: Control Responses

  private func sendControlResponse(requestId: String, approved: Bool, result: String? = nil) {
    let response: [String: Any]
    if approved {
      var successResponse: [String: Any] = [
        "subtype": "success",
        "request_id": requestId,
      ]
      var responseBody: [String: Any] = ["behavior": "allow"]
      if let result = result {
        responseBody["result"] = result
      }
      successResponse["response"] = responseBody
      response = ["type": "control_response", "response": successResponse]
    } else {
      response = [
        "type": "control_response",
        "response": [
          "subtype": "error",
          "request_id": requestId,
          "error": "Permission denied by user",
        ] as [String: Any],
      ]
    }

    if let data = try? JSONSerialization.data(withJSONObject: response),
      let jsonString = String(data: data, encoding: .utf8)
    {
      sendLine(jsonString)
    }
  }

  // MARK: - Private: Tool Classification

  /// Returns true if this is an Omi-local tool that should be executed Swift-side
  private func isVibeAiLocalTool(_ name: String) -> Bool {
    let vibeAiTools: Set<String> = [
      "execute_sql", "semantic_search",
      "complete_task", "delete_task",
      "get_daily_recap",
      "request_permission", "check_permission_status",
      "scan_files", "start_file_scan", "get_file_scan_results",
      "set_user_preferences", "ask_followup",
      "complete_onboarding", "save_knowledge_graph",
    ]
    return vibeAiTools.contains(name)
  }

  // MARK: - Private: Pipe I/O

  private func sendLine(_ line: String) {
    guard let pipe = stdinPipe else { return }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = (trimmed + "\n").data(using: .utf8) {
      do {
        try pipe.fileHandleForWriting.write(contentsOf: data)
      } catch {
        log("ClaudeCodeBridge: Failed to write to stdin: \(error.localizedDescription)")
      }
    }
  }

  private func deliverMessage(_ message: InboundMessage) {
    if let continuation = messageContinuation {
      messageContinuation = nil
      continuation.resume(returning: message)
    } else {
      pendingMessages.append(message)
    }
  }

  private func waitForMessage(timeout: TimeInterval? = nil) async throws -> InboundMessage {
    if !pendingMessages.isEmpty {
      return pendingMessages.removeFirst()
    }

    messageGeneration &+= 1
    let expectedGeneration = messageGeneration

    return try await withCheckedThrowingContinuation { continuation in
      self.messageContinuation = continuation

      if let timeout = timeout {
        Task {
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          if self.messageGeneration == expectedGeneration, self.messageContinuation != nil {
            self.messageContinuation = nil
            continuation.resume(throwing: BridgeError.timeout)
          }
        }
      }
    }
  }

  private func handleTermination(
    exitCode: Int32 = -1, reason: Process.TerminationReason = .exit, generation: UInt64? = nil
  ) {
    if let gen = generation, gen != processGeneration {
      log("ClaudeCodeBridge: ignoring stale termination (gen=\(gen), current=\(processGeneration))")
      return
    }

    let reasonStr = reason == .uncaughtSignal ? "signal" : "exit"
    log("ClaudeCodeBridge: process terminated (code=\(exitCode), reason=\(reasonStr))")

    // Don't set isRunning=false — the bridge stays alive across queries.
    // Each query spawns a new claude process.
    closePipes()
    messageContinuation?.resume(throwing: BridgeError.processExited)
    messageContinuation = nil
  }

  private func closePipes() {
    if let stdin = stdinPipe {
      try? stdin.fileHandleForWriting.close()
      try? stdin.fileHandleForReading.close()
    }
    if let stdout = stdoutPipe {
      stdout.fileHandleForReading.readabilityHandler = nil
      try? stdout.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
    }
    if let stderr = stderrPipe {
      stderr.fileHandleForReading.readabilityHandler = nil
      try? stderr.fileHandleForReading.close()
      try? stderr.fileHandleForWriting.close()
    }
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
  }

  // MARK: - Binary Discovery

  private func findClaudeBinary() -> String? {
    // 1. Check bundled claude binary
    let bundled = Bundle.resourceBundle.path(forResource: "claude", ofType: nil)
    if let bundled, FileManager.default.isExecutableFile(atPath: bundled) {
      return bundled
    }

    // 2. Common install locations
    let candidates = [
      "/usr/local/bin/claude",
      "/opt/homebrew/bin/claude",
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/local/claude",
    ]
    for path in candidates {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // 3. npm global installs
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let npmGlobal = "\(home)/.npm-global/bin/claude"
    if FileManager.default.isExecutableFile(atPath: npmGlobal) {
      return npmGlobal
    }

    // 4. Try `which claude` via shell
    let whichProc = Process()
    whichProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    whichProc.arguments = ["-l", "-c", "source ~/.zprofile 2>/dev/null; source ~/.zshrc 2>/dev/null; which claude"]
    let pipe = Pipe()
    whichProc.standardOutput = pipe
    whichProc.standardError = Pipe()
    try? whichProc.run()
    whichProc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    {
      return path
    }

    return nil
  }

  private func findNodeBinary() -> String? {
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
    ]
    for path in candidates {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Check NVM
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let nvmDir = "\(home)/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
      let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      for version in sorted {
        let nodePath = "\(nvmDir)/\(version)/bin/node"
        if FileManager.default.isExecutableFile(atPath: nodePath) {
          return nodePath
        }
      }
    }

    return nil
  }
}
