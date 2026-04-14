import Foundation

/// Builds MCP server configuration JSON for Claude Code's --mcp-config flag.
/// This replaces the ACP Bridge's vibeai-tools relay and Playwright MCP setup.
struct ClaudeCodeMCPConfig {

  struct MCPServer {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
  }

  /// Build the MCP config JSON string for passing to `--mcp-config`.
  /// Returns a JSON object like: {"mcpServers": {"name": {"command": ..., "args": [...], "env": {...}}}}
  static func buildConfigJSON(servers: [MCPServer]) -> String? {
    var serversDict: [String: Any] = [:]
    for server in servers {
      var entry: [String: Any] = [
        "command": server.command,
        "args": server.args,
      ]
      if !server.env.isEmpty {
        entry["env"] = server.env
      }
      serversDict[server.name] = entry
    }

    let config: [String: Any] = ["mcpServers": serversDict]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return json
  }

  /// Write MCP config to a temp file and return the path.
  /// Claude Code accepts `--mcp-config <path>` pointing to a JSON file.
  static func writeConfigFile(servers: [MCPServer]) -> String? {
    guard let json = buildConfigJSON(servers: servers) else { return nil }
    let path = NSTemporaryDirectory() + "claude-code-mcp-\(ProcessInfo.processInfo.processIdentifier).json"
    do {
      try json.write(toFile: path, atomically: true, encoding: .utf8)
      return path
    } catch {
      log("ClaudeCodeMCPConfig: failed to write config file: \(error)")
      return nil
    }
  }

  /// Build the default set of MCP servers for the Omi desktop app.
  /// Includes vibeai-tools (via stdio) and optionally Playwright.
  static func defaultServers(
    nodePath: String,
    bridgePipePath: String,
    cwd: String,
    mode: String,
    includePlaywright: Bool = false,
    playwrightToken: String? = nil
  ) -> [MCPServer] {
    var servers: [MCPServer] = []

    // vibeai-tools MCP server (communicates with Swift via Unix socket)
    let vibeaiToolsPath = findVibeaiToolsScript()
    if let toolsPath = vibeaiToolsPath {
      var env: [String: String] = [
        "OMI_BRIDGE_PIPE": bridgePipePath,
        "OMI_QUERY_MODE": mode,
        "OMI_WORKSPACE": cwd,
      ]
      // Pass through API-related env vars
      if let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
        env["ANTHROPIC_API_KEY"] = apiKey
      }
      servers.append(MCPServer(
        name: "vibeai-tools",
        command: nodePath,
        args: [toolsPath],
        env: env
      ))
    }

    // Playwright MCP server (browser automation)
    if includePlaywright {
      let playwrightCli = findPlaywrightMCPScript(nodePath: nodePath)
      if let cli = playwrightCli {
        var env: [String: String] = [
          "PLAYWRIGHT_USE_EXTENSION": "true",
        ]
        if let token = playwrightToken, !token.isEmpty {
          env["PLAYWRIGHT_MCP_EXTENSION_TOKEN"] = token
        }
        servers.append(MCPServer(
          name: "playwright",
          command: nodePath,
          args: [cli],
          env: env
        ))
      }
    }

    return servers
  }

  // MARK: - Script Discovery

  private static func findVibeaiToolsScript() -> String? {
    // Check in app bundle
    if let bundlePath = Bundle.main.resourcePath {
      let bundled = (bundlePath as NSString).appendingPathComponent("acp-bridge/dist/vibeai-tools-stdio.mjs")
      if FileManager.default.fileExists(atPath: bundled) {
        return bundled
      }
    }

    // Check relative to executable (development)
    if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
      let devPaths = [
        execDir.appendingPathComponent("../../../acp-bridge/dist/vibeai-tools-stdio.mjs").path,
        execDir.appendingPathComponent("../../../../acp-bridge/dist/vibeai-tools-stdio.mjs").path,
      ]
      for path in devPaths {
        let resolved = (path as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolved) {
          return resolved
        }
      }
    }

    // Check cwd
    let cwdPath = FileManager.default.currentDirectoryPath
    let cwdScript = (cwdPath as NSString).appendingPathComponent("acp-bridge/dist/vibeai-tools-stdio.mjs")
    if FileManager.default.fileExists(atPath: cwdScript) {
      return cwdScript
    }

    return nil
  }

  private static func findPlaywrightMCPScript(nodePath: String) -> String? {
    // Look for @playwright/mcp in node_modules near the acp-bridge
    if let bundlePath = Bundle.main.resourcePath {
      let bundled = (bundlePath as NSString).appendingPathComponent(
        "acp-bridge/node_modules/@playwright/mcp/cli.mjs")
      if FileManager.default.fileExists(atPath: bundled) {
        return bundled
      }
    }

    if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
      let devPaths = [
        execDir.appendingPathComponent("../../../acp-bridge/node_modules/@playwright/mcp/cli.mjs").path,
        execDir.appendingPathComponent("../../../../acp-bridge/node_modules/@playwright/mcp/cli.mjs").path,
      ]
      for path in devPaths {
        let resolved = (path as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolved) {
          return resolved
        }
      }
    }

    return nil
  }
}
