import Foundation

/// Protocol that both ACPBridge and ClaudeCodeBridge conform to,
/// allowing ChatProvider to swap between them via a feature flag.
protocol ChatBridge: Actor {

  // MARK: - Types

  typealias TextDeltaHandler = @Sendable (String) -> Void
  typealias ToolCallHandler = @Sendable (String, String, [String: Any]) async -> String
  typealias ToolActivityHandler = @Sendable (String, String, String?, [String: Any]?) -> Void
  typealias ThinkingDeltaHandler = @Sendable (String) -> Void
  typealias ToolResultDisplayHandler = @Sendable (String, String, String) -> Void
  typealias AuthRequiredHandler = @Sendable ([[String: Any]], String?) -> Void
  typealias AuthSuccessHandler = @Sendable () -> Void

  // MARK: - Properties

  var passApiKey: Bool { get }
  var isAlive: Bool { get }

  // MARK: - Lifecycle

  func start() async throws
  func restart() async throws
  func stop()

  // MARK: - Auth

  func setGlobalAuthHandlers(
    onAuthRequired: AuthRequiredHandler?,
    onAuthSuccess: AuthSuccessHandler?
  )
  func authenticate(methodId: String)

  // MARK: - Session

  func warmupSession(cwd: String?, sessions: [WarmupSessionConfig])

  // MARK: - Query

  func query(
    prompt: String,
    systemPrompt: String,
    sessionKey: String?,
    cwd: String?,
    mode: String?,
    model: String?,
    resume: String?,
    imageData: Data?,
    onTextDelta: @escaping TextDeltaHandler,
    onToolCall: @escaping ToolCallHandler,
    onToolActivity: @escaping ToolActivityHandler,
    onThinkingDelta: @escaping ThinkingDeltaHandler,
    onToolResultDisplay: @escaping ToolResultDisplayHandler,
    onAuthRequired: @escaping AuthRequiredHandler,
    onAuthSuccess: @escaping AuthSuccessHandler
  ) async throws -> ChatBridgeQueryResult

  // MARK: - Controls

  func interrupt()
  func testPlaywrightConnection() async throws -> Bool
}

/// Shared query result type for both bridge implementations
struct ChatBridgeQueryResult {
  let text: String
  let costUsd: Double
  let sessionId: String
  let inputTokens: Int
  let outputTokens: Int
  let cacheReadTokens: Int
  let cacheWriteTokens: Int
}

/// Shared warmup session config
struct WarmupSessionConfig {
  let key: String
  let model: String
  let systemPrompt: String?
}
