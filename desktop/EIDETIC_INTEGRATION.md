# Eidetic Memory Integration Guide for Omi Desktop

Two integration paths are available. Use one or both:

| Path | Best for | Latency | Setup |
|------|----------|---------|-------|
| **Path A: MCP Server** | LLM agent tool calls, quick integration | ~50ms (subprocess) | Add MCP config, no code changes |
| **Path B: Direct Rust crate** | Auto-save/recall hooks, tight integration | ~5ms (in-process) | Add Cargo dependency, write routes |

Both paths share the same graph file (`~/.omi/memory/graph.json`) so they can be used together.

---

## What Eidetic Memory Is

A Rust memory engine that:
- Ingests conversation text and extracts typed memories (facts, decisions, preferences, insights, questions)
- Classifies memories into topic rooms automatically via keyword scoring
- Stores everything in a persistent JSON-backed wiki graph
- Recalls memories using hybrid search (text scoring + alias lookup + vector cosine similarity + graph expansion, fused via Reciprocal Rank Fusion)
- Embeds memories using all-MiniLM-L6-v2 (via fastembed) for semantic matching
- Benchmarked at 95.4% R@5 on LongMemEval (1.2 pts behind MemPalace)

**Crate:** `eidetic-core` (pure Rust, no C++ deps for the FileGraph backend)
**Location:** `/Users/dzineer/Clients/Dzineer/Projects/eidetic_memory/crates/eidetic-core`
**Tests:** 405 passing

---

---

# Path A: MCP Server (Zero Code Integration)

The MCP server exposes 6 tools over stdio JSON-RPC. Any MCP-aware client can use it.

## MCP Server Binary

```bash
# Build once
cd /Users/dzineer/Clients/Dzineer/Projects/eidetic_memory
cargo build --release -p eidetic-mcp

# Binary at: target/release/eidetic-mcp
```

## Available MCP Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `memory_init` | Create identity node (root of memory tower) | `name?`, `traits?`, `projects?`, `context?` |
| `memory_save` | Save inline text as a memory | `text`, `source?` |
| `memory_save_conversation` | Save conversation with turn markers | `text`, `source?` |
| `memory_save_raw` | Save free-form text (paragraph splitting) | `text`, `source?` |
| `memory_query` | Hybrid search (text + vector + alias + graph) | `query`, `limit?` |
| `memory_status` | Graph stats, rooms, node counts | (none) |

## Add to Omi as an MCP Server

If Omi supports MCP server configuration (like Claude Code does):

```json
{
  "mcpServers": {
    "eidetic": {
      "command": "/Users/dzineer/Clients/Dzineer/Projects/eidetic_memory/target/release/eidetic-mcp",
      "args": []
    }
  }
}
```

## Calling MCP Tools from Omi's Backend

If Omi's LLM agent supports tool calling, add the MCP tools to its tool list. The agent can then autonomously decide when to save and recall memories.

If Omi needs to call tools programmatically (not via LLM), spawn the MCP server as a subprocess and send JSON-RPC messages over stdin/stdout:

```rust
use std::process::{Command, Stdio};
use std::io::{Write, BufRead, BufReader};

fn call_mcp_tool(tool: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
    let mut child = Command::new("target/release/eidetic-mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn: {e}"))?;

    let stdin = child.stdin.as_mut().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());

    // Initialize
    let init = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "omi", "version": "1.0"}
        }
    });
    writeln!(stdin, "{}", init).map_err(|e| format!("write: {e}"))?;

    // Notification
    let notif = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
    writeln!(stdin, "{}", notif).map_err(|e| format!("write: {e}"))?;

    // Call tool
    let call = serde_json::json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": tool, "arguments": args}
    });
    writeln!(stdin, "{}", call).map_err(|e| format!("write: {e}"))?;

    // Read responses (skip init response, get tool response)
    let mut lines = stdout.lines();
    let _ = lines.next(); // init response
    let result_line = lines.next()
        .ok_or("no response")?
        .map_err(|e| format!("read: {e}"))?;

    serde_json::from_str(&result_line).map_err(|e| format!("parse: {e}"))
}

// Usage:
let result = call_mcp_tool("memory_save", serde_json::json!({
    "text": "I prefer morning meetings"
}))?;

let result = call_mcp_tool("memory_query", serde_json::json!({
    "query": "meeting preferences",
    "limit": 5
}))?;
```

For a long-running integration, keep the MCP server process alive and reuse the stdin/stdout connection instead of spawning per call.

---

# Path B: Direct Rust Crate (Faster, Tighter Integration)

Direct integration is ~10x faster (no subprocess overhead) and gives full access to the graph API. Use this for auto-save/recall hooks that run on every conversation turn.

## Step 1: Add Dependency

In `Backend-Rust/Cargo.toml`, add:

```toml
[dependencies]
# ... existing deps ...
eidetic-core = { path = "../../../eidetic_memory/crates/eidetic-core" }
fastembed = "5"
```

If you prefer not to use a local path, the crate can be published to crates.io.

The `fastembed` dependency is needed for embedding generation. It pulls in ONNX Runtime (~50MB) and will download the MiniLM model (~90MB) on first run.

---

## Step 2: Create a Memory Service

Create `Backend-Rust/src/services/memory.rs`:

```rust
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

use eidetic_core::{
    ingest, ingest_inline, ingest_raw,
    FileGraph, GraphBackend, IngestConfig, NodeKind,
    pipeline::{recall_pipeline, RecallConfig},
    recall::RankedHit,
};

pub struct MemoryService {
    graph_path: PathBuf,
    seen_path: PathBuf,
    embedder: Mutex<Option<fastembed::TextEmbedding>>,
}

impl MemoryService {
    pub fn new() -> Self {
        let dir = dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".omi")
            .join("memory");
        std::fs::create_dir_all(&dir).ok();

        // Load embedder (takes ~1s on first call, downloads model if needed)
        let embedder = fastembed::TextEmbedding::try_new(
            fastembed::InitOptions::new(fastembed::EmbeddingModel::AllMiniLML6V2)
                .with_show_download_progress(false),
        )
        .ok();

        Self {
            graph_path: dir.join("graph.json"),
            seen_path: dir.join("seen.json"),
            embedder: Mutex::new(embedder),
        }
    }

    /// Save a memory (inline text).
    /// Returns (memories_stored, rooms).
    pub fn save(&self, text: &str, source: Option<&str>) -> Result<SaveResult, String> {
        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;
        let seen = self.load_seen();

        let config = IngestConfig {
            source: source.map(|s| s.to_string()).or(Some("omi".to_string())),
            ..Default::default()
        };

        let result = ingest_inline(text, &graph, &config, &seen)
            .map_err(|e| format!("ingest: {e}"))?;

        // Update seen hashes
        let extracted = eidetic_core::extract_inline(text, config.source.as_deref(), &HashSet::new());
        let mut seen = seen;
        for mem in &extracted {
            seen.insert(mem.content_hash.clone());
        }
        self.save_seen(&seen);

        // Embed stored memories for vector search
        for node_id in &result.memory_node_ids {
            if let Ok(Some(node)) = graph.get_node(*node_id) {
                if !node.payload.trim().is_empty() {
                    if let Some(emb) = self.embed_text(&node.payload) {
                        let _ = graph.put_embedding(*node_id, emb);
                    }
                }
            }
        }

        Ok(SaveResult {
            stored: result.memories_stored,
            rooms: result.rooms,
        })
    }

    /// Save a full conversation (with ### USER / ### ASSISTANT markers).
    pub fn save_conversation(&self, text: &str, source: Option<&str>) -> Result<SaveResult, String> {
        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;
        let seen = self.load_seen();

        let config = IngestConfig {
            source: source.map(|s| s.to_string()).or(Some("omi-conversation".to_string())),
            ..Default::default()
        };

        let result = ingest(text, &graph, &config, &seen)
            .map_err(|e| format!("ingest: {e}"))?;

        let extracted = eidetic_core::extract_memories(text, config.source.as_deref(), &HashSet::new());
        let mut seen = seen;
        for mem in &extracted {
            seen.insert(mem.content_hash.clone());
        }
        self.save_seen(&seen);

        // Embed
        for node_id in &result.memory_node_ids {
            if let Ok(Some(node)) = graph.get_node(*node_id) {
                if !node.payload.trim().is_empty() {
                    if let Some(emb) = self.embed_text(&node.payload) {
                        let _ = graph.put_embedding(*node_id, emb);
                    }
                }
            }
        }

        Ok(SaveResult {
            stored: result.memories_stored,
            rooms: result.rooms,
        })
    }

    /// Query memories. Returns ranked results with payloads.
    pub fn query(&self, query: &str, limit: usize) -> Result<Vec<MemoryHit>, String> {
        if !self.graph_path.exists() {
            return Ok(Vec::new());
        }

        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;

        // Set query embedding for vector search
        if graph.embedding_count() > 0 {
            if let Some(emb) = self.embed_text(query) {
                FileGraph::set_query_embedding(emb);
            }
        }

        let config = RecallConfig {
            per_source_k: limit * 2,
            final_k: limit,
            expand_depth: 1,
            expand_filter: None,
            ..Default::default()
        };

        let result = recall_pipeline(query, &graph, &graph, &graph, &graph, &config)
            .map_err(|e| format!("recall: {e}"))?;

        let mut hits = Vec::new();
        for seed in &result.seeds {
            if let Ok(Some(node)) = graph.get_node(seed.id) {
                hits.push(MemoryHit {
                    id: seed.id.to_string(),
                    kind: node.kind.name().to_string(),
                    payload: node.payload.clone(),
                    score: seed.score,
                    alias: node.alias.clone(),
                });
            }
        }

        Ok(hits)
    }

    /// Get graph statistics.
    pub fn status(&self) -> Result<MemoryStatus, String> {
        if !self.graph_path.exists() {
            return Ok(MemoryStatus {
                nodes: 0,
                edges: 0,
                embeddings: 0,
                rooms: Vec::new(),
            });
        }

        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;

        let rooms: Vec<String> = graph
            .nodes_by_kind(NodeKind::Room)
            .iter()
            .filter_map(|n| n.alias.clone())
            .collect();

        Ok(MemoryStatus {
            nodes: graph.node_count(),
            edges: graph.edge_count(),
            embeddings: graph.embedding_count(),
            rooms,
        })
    }

    fn embed_text(&self, text: &str) -> Option<Vec<f32>> {
        let mut guard = self.embedder.lock().ok()?;
        let model = guard.as_mut()?;
        model.embed(vec![text], None).ok()?.into_iter().next()
    }

    fn load_seen(&self) -> HashSet<String> {
        if self.seen_path.exists() {
            let data = std::fs::read_to_string(&self.seen_path).unwrap_or_default();
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            HashSet::new()
        }
    }

    fn save_seen(&self, seen: &HashSet<String>) {
        if let Ok(json) = serde_json::to_string(seen) {
            let _ = std::fs::write(&self.seen_path, json);
        }
    }
}

#[derive(serde::Serialize)]
pub struct SaveResult {
    pub stored: usize,
    pub rooms: std::collections::HashMap<String, usize>,
}

#[derive(serde::Serialize)]
pub struct MemoryHit {
    pub id: String,
    pub kind: String,
    pub payload: String,
    pub score: f32,
    pub alias: Option<String>,
}

#[derive(serde::Serialize)]
pub struct MemoryStatus {
    pub nodes: usize,
    pub edges: usize,
    pub embeddings: usize,
    pub rooms: Vec<String>,
}
```

Add to `Backend-Rust/src/services/mod.rs`:

```rust
pub mod memory;
```

---

## Step 3: Add Axum Routes

Create `Backend-Rust/src/routes/memory.rs`:

```rust
use axum::{extract::State, Json};
use serde::Deserialize;
use std::sync::Arc;

use crate::services::memory::{MemoryService, MemoryHit, MemoryStatus, SaveResult};

#[derive(Deserialize)]
pub struct SaveRequest {
    pub text: String,
    pub source: Option<String>,
    /// If true, treat as a conversation with ### USER / ### ASSISTANT markers.
    /// If false (default), treat as inline text.
    #[serde(default)]
    pub conversation: bool,
}

#[derive(Deserialize)]
pub struct QueryRequest {
    pub query: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize { 5 }

pub async fn save_memory(
    State(memory): State<Arc<MemoryService>>,
    Json(req): Json<SaveRequest>,
) -> Json<serde_json::Value> {
    let result = if req.conversation {
        memory.save_conversation(&req.text, req.source.as_deref())
    } else {
        memory.save(&req.text, req.source.as_deref())
    };

    match result {
        Ok(r) => Json(serde_json::json!({
            "ok": true,
            "stored": r.stored,
            "rooms": r.rooms,
        })),
        Err(e) => Json(serde_json::json!({
            "ok": false,
            "error": e,
        })),
    }
}

pub async fn query_memory(
    State(memory): State<Arc<MemoryService>>,
    Json(req): Json<QueryRequest>,
) -> Json<serde_json::Value> {
    match memory.query(&req.query, req.limit) {
        Ok(hits) => Json(serde_json::json!({
            "ok": true,
            "results": hits,
        })),
        Err(e) => Json(serde_json::json!({
            "ok": false,
            "error": e,
        })),
    }
}

pub async fn memory_status(
    State(memory): State<Arc<MemoryService>>,
) -> Json<serde_json::Value> {
    match memory.status() {
        Ok(s) => Json(serde_json::json!({
            "ok": true,
            "nodes": s.nodes,
            "edges": s.edges,
            "embeddings": s.embeddings,
            "rooms": s.rooms,
        })),
        Err(e) => Json(serde_json::json!({
            "ok": false,
            "error": e,
        })),
    }
}
```

Add to `Backend-Rust/src/routes/mod.rs`:

```rust
pub mod memory;
```

---

## Step 4: Register Routes in main.rs

In `Backend-Rust/src/main.rs`, add:

```rust
use std::sync::Arc;
use crate::services::memory::MemoryService;

// In your router setup:
let memory_service = Arc::new(MemoryService::new());

let app = Router::new()
    // ... existing routes ...
    .route("/api/memory/save", post(routes::memory::save_memory))
    .route("/api/memory/query", post(routes::memory::query_memory))
    .route("/api/memory/status", get(routes::memory::memory_status))
    .with_state(memory_service);
```

Note: If you use a different state pattern (e.g., `AppState` struct), wrap `MemoryService` inside it.

---

## Step 5: Auto-Save After Each Conversation

In whichever handler processes a completed conversation turn, add:

```rust
// After the LLM responds:
let conversation_text = format!(
    "### USER\n{}\n\n### ASSISTANT\n{}\n",
    user_transcript, ai_response
);

// Fire-and-forget (don't block the response)
let memory = memory_service.clone();
tokio::spawn(async move {
    let _ = memory.save_conversation(&conversation_text, Some("omi-session"));
});
```

This saves every exchange as a memory automatically. Dedup prevents the same conversation from being stored twice.

---

## Step 6: Auto-Recall Before Each LLM Call

Before building the LLM prompt, query for relevant context:

```rust
// Before calling the LLM:
let memories = memory_service.query(&user_transcript, 5)
    .unwrap_or_default();

let memory_context = if memories.is_empty() {
    String::new()
} else {
    let mut ctx = String::from("Relevant memories from previous conversations:\n");
    for hit in &memories {
        ctx.push_str(&format!("- {}\n", hit.payload));
    }
    ctx
};

// Prepend to system prompt or inject as context:
let system_prompt = format!(
    "{}\n\n{}\n\n{}",
    base_system_prompt,
    memory_context,
    "Use the above memories to provide personalized, context-aware responses."
);
```

---

## Step 7: Swift UI Integration (Optional)

### Show Memory Count in Settings

Call `GET /api/memory/status` from Swift and display:

```swift
struct MemoryStatusView: View {
    @State private var nodeCount: Int = 0
    @State private var rooms: [String] = []

    var body: some View {
        VStack(alignment: .leading) {
            Text("Memory").font(.headline)
            Text("\(nodeCount) memories stored")
            if !rooms.isEmpty {
                Text("Rooms: \(rooms.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { fetchStatus() }
    }

    func fetchStatus() {
        // GET http://localhost:{port}/api/memory/status
    }
}
```

### "What Do You Remember?" Query

Add a search field that calls `POST /api/memory/query`:

```swift
TextField("Ask your memory...", text: $query)
    .onSubmit {
        // POST http://localhost:{port}/api/memory/query
        // body: {"query": query, "limit": 10}
        // Display results
    }
```

---

## Data Storage

All memory data is stored locally:

```
~/.omi/memory/
  graph.json     — nodes, edges, and embeddings (single JSON file)
  seen.json      — SHA-256 hashes of already-ingested content (dedup)
```

The graph.json file contains:
- **Nodes**: memories (Concept), rooms (Room), identity (Identity)
- **Edges**: memory-to-room links (RelatesTo)
- **Embeddings**: 384-dim vectors per memory node (all-MiniLM-L6-v2)

Typical size: ~1MB per 1,000 memories.

---

## Key API Reference

### eidetic_core public functions used:

| Function | What it does |
|----------|-------------|
| `FileGraph::open(path)` | Open or create a JSON graph file |
| `ingest(text, graph, config, seen)` | Ingest conversation (### USER/### ASSISTANT) |
| `ingest_inline(text, graph, config, seen)` | Ingest single text as one memory |
| `recall_pipeline(query, vec, alias, text, graph, config)` | Hybrid search with RRF fusion |
| `FileGraph::set_query_embedding(vec)` | Set query vector for cosine search |
| `graph.put_embedding(id, vec)` | Store embedding for a node |
| `graph.embedding_count()` | Number of stored embeddings |
| `graph.nodes_by_kind(kind)` | Get all nodes of a specific type |
| `graph.node_count()` / `edge_count()` | Graph statistics |

### IngestConfig fields:

```rust
IngestConfig {
    source: Some("omi-session".to_string()),  // provenance label
    room_config: RoomConfig::default(),        // keyword dict for classification
}
```

### RecallConfig fields:

```rust
RecallConfig {
    per_source_k: 10,      // top-K from each source before fusion
    final_k: 5,            // final results after RRF
    expand_depth: 1,        // BFS hops from seeds
    expand_filter: None,    // edge kind filter (None = all)
    rrf_k: 60.0,           // RRF smoothing constant
}
```

---

## Performance

| Operation | Latency | Notes |
|-----------|---------|-------|
| Save (inline) | ~50ms + embed time | Embed adds ~20ms per memory |
| Save (conversation, 10 turns) | ~100ms + embed time | |
| Query (with embeddings) | ~30ms | Cosine scan over all embeddings |
| Query (text-only) | ~5ms | No embedding model needed |
| Model load (first call) | ~1s | Downloads 90MB model on first run |
| Memory per 1K nodes | ~5MB RSS | Graph + embeddings in memory |

---

## Benchmark

LongMemEval-S (500 questions, session-level retrieval):

| Config | R@5 |
|--------|----:|
| Eidetic (text + vector) | **95.4%** |
| MemPalace raw (ChromaDB) | 96.6% |
| MemPalace best (+ LLM rerank) | 99.4% |

---

## What the User Gets

1. **Omi remembers preferences**: "I prefer morning meetings" is saved, recalled next time scheduling comes up
2. **Cross-conversation context**: "What did we discuss about the project?" searches all past conversations
3. **Automatic topic rooms**: Memories auto-classify into architecture, testing, planning, learning, etc.
4. **All local**: No cloud storage, no API calls for memory (only for embedding model download on first run)
5. **Dedup built in**: Same conversation ingested twice stores nothing new
6. **Fast**: Sub-100ms save and query on typical workloads
