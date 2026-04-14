import Foundation

// MARK: - Claude Code Stream-JSON Message Types
// These map to the NDJSON output from `claude -p --output-format stream-json`

/// Top-level message envelope from Claude Code stdout
struct ClaudeCodeMessage: Decodable {
  let type: String
  let uuid: String?
  let session_id: String?

  // Fields for "assistant" type
  let message: AssistantMessageBody?
  let parent_tool_use_id: String?
  let error: String?

  // Fields for "stream_event" type
  let event: StreamEvent?

  // Fields for "result" type
  let subtype: String?
  let duration_ms: Int?
  let duration_api_ms: Int?
  let is_error: Bool?
  let num_turns: Int?
  let result: ClaudeAnyValue?
  let stop_reason: String?
  let total_cost_usd: Double?
  let usage: TokenUsage?
  let modelUsage: [String: ModelUsageEntry]?
  let permission_denials: [PermissionDenial]?
  let errors: [String]?
  let fast_mode_state: String?

  // Fields for "system" type
  let status: String?
  let agents: [String]?
  let apiKeySource: String?
  let betas: [String]?
  let claude_code_version: String?
  let cwd: String?
  let tools: [String]?
  let mcp_servers: [MCPServerStatus]?
  let model: String?
  let permissionMode: String?

  // Fields for "control_request" type
  let request_id: String?
  let request: ControlRequestBody?

  // Fields for "tool_progress" type
  let tool_use_id: String?
  let tool_name: String?
  let elapsed_time_seconds: Double?
  let task_id: String?

  // Fields for "tool_use_summary" type
  let summary: String?
  let preceding_tool_use_ids: [String]?
  let tool_summary: String?

  // Fields for task messages
  let description: String?
  let task_type: String?
  let workflow_name: String?
  let prompt: String?
  let last_tool_name: String?

  // Auth status fields
  let isAuthenticating: Bool?
  let output: [String]?

  // Hook fields
  let hook_id: String?
  let hook_name: String?
  let hook_event: String?
  let stdout_text: String?
  let stderr_text: String?
  let exit_code: Int?
  let outcome: String?

  // System message content field
  let content: String?

  private enum CodingKeys: String, CodingKey {
    case type, uuid, session_id
    case message, parent_tool_use_id, error
    case event
    case subtype, duration_ms, duration_api_ms, is_error, num_turns, result
    case stop_reason, total_cost_usd, usage, modelUsage
    case permission_denials, errors, fast_mode_state
    case status, agents, apiKeySource, betas, claude_code_version, cwd
    case tools, mcp_servers, model, permissionMode
    case request_id, request
    case tool_use_id, tool_name, elapsed_time_seconds, task_id
    case summary, preceding_tool_use_ids, tool_summary
    case description, task_type, workflow_name, prompt, last_tool_name
    case isAuthenticating, output
    case hook_id, hook_name, hook_event
    case stdout_text = "stdout"
    case stderr_text = "stderr"
    case exit_code, outcome
    case content
  }
}

// MARK: - Assistant Message Body

struct AssistantMessageBody: Decodable {
  let role: String?
  let content: [ContentBlock]?
}

// MARK: - Content Blocks

struct ContentBlock: Decodable {
  let type: String
  let text: String?
  let id: String?
  let name: String?
  let input: ClaudeAnyValue?
  let thinking: String?
  let partial_json: String?

  // For tool_result blocks
  let tool_use_id: String?
  let content: ClaudeAnyValue?
  let is_error: Bool?
}

// MARK: - Stream Events

struct StreamEvent: Decodable {
  let type: String
  let index: Int?
  let delta: StreamDelta?
  let content_block: ContentBlock?
}

struct StreamDelta: Decodable {
  let type: String
  let text: String?
  let thinking: String?
  let partial_json: String?
}

// MARK: - Token Usage

struct TokenUsage: Decodable {
  let input_tokens: Int?
  let output_tokens: Int?
  let cache_read_input_tokens: Int?
  let cache_creation_input_tokens: Int?
}

struct ModelUsageEntry: Decodable {
  let inputTokens: Int?
  let outputTokens: Int?
  let cacheReadInputTokens: Int?
  let cacheCreationInputTokens: Int?
  let webSearchRequests: Int?
  let costUSD: Double?
  let contextWindow: Int?
  let maxOutputTokens: Int?
}

// MARK: - Permission / Control

struct PermissionDenial: Decodable {
  let tool_name: String?
  let tool_use_id: String?
  let tool_input: ClaudeAnyValue?
}

struct ControlRequestBody: Decodable {
  let subtype: String?
  let tool_name: String?
  let input: ClaudeAnyValue?
  let permission_suggestions: [ClaudeAnyValue]?
  let blocked_path: String?
  let decision_reason: String?
  let tool_use_id: String?
  let agent_id: String?
  let action_description: String?
  // For hook_callback
  let callback_id: String?
  // For mcp_message
  let server_name: String?
  let mcp_message: ClaudeAnyValue?

  private enum CodingKeys: String, CodingKey {
    case subtype, tool_name, input, permission_suggestions
    case blocked_path, decision_reason, tool_use_id, agent_id
    case action_description, callback_id, server_name
    case mcp_message = "message"
  }
}

// MARK: - MCP Server Status

struct MCPServerStatus: Decodable {
  let name: String?
  let status: String?
}

// MARK: - ClaudeAnyValue (type-erased JSON value)

struct ClaudeAnyValue: Decodable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([ClaudeAnyValue].self) {
      value = array.map { $0.value }
    } else if let dict = try? container.decode([String: ClaudeAnyValue].self) {
      value = dict.mapValues { $0.value }
    } else {
      value = NSNull()
    }
  }

  var stringValue: String? { value as? String }
  var intValue: Int? { value as? Int }
  var doubleValue: Double? { value as? Double }
  var boolValue: Bool? { value as? Bool }
  var dictValue: [String: Any]? { value as? [String: Any] }
  var arrayValue: [Any]? { value as? [Any] }
}
