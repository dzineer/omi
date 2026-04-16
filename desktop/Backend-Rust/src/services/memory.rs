use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

use eidetic_core::{
    ingest, ingest_inline,
    FileGraph, GraphBackend, IngestConfig, NodeKind,
    pipeline::{recall_pipeline, RecallConfig},
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
            .join(".vibeai")
            .join("memory");
        std::fs::create_dir_all(&dir).ok();

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

        let extracted = eidetic_core::extract_inline(text, config.source.as_deref(), &HashSet::new());
        let mut seen = seen;
        for mem in &extracted {
            seen.insert(mem.content_hash.clone());
        }
        self.save_seen(&seen);

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

    pub fn query(&self, query: &str, limit: usize) -> Result<Vec<MemoryHit>, String> {
        if !self.graph_path.exists() {
            return Ok(Vec::new());
        }

        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;

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

    /// Return the full graph structure for visualization.
    pub fn graph(&self) -> Result<GraphData, String> {
        if !self.graph_path.exists() {
            return Ok(GraphData {
                nodes: Vec::new(),
                edges: Vec::new(),
                rooms: Vec::new(),
            });
        }

        let graph = FileGraph::open(&self.graph_path)
            .map_err(|e| format!("graph open: {e}"))?;

        let mut nodes = Vec::new();
        let mut rooms_map: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

        // Collect all nodes
        for kind in &[NodeKind::Concept, NodeKind::Room, NodeKind::Identity] {
            for node in graph.nodes_by_kind(*kind) {
                let room = self.classify_to_room(&node.payload);
                *rooms_map.entry(room.clone()).or_insert(0) += 1;

                nodes.push(GraphNode {
                    id: node.id.to_string(),
                    kind: node.kind.name().to_string(),
                    payload: node.payload.clone(),
                    alias: node.alias.clone(),
                    room,
                });
            }
        }

        // Build edges from room membership (each memory connects to its room)
        let mut edges = Vec::new();
        for node in &nodes {
            if node.kind != "room" {
                // Connect memory to its room node
                edges.push(GraphEdge {
                    from: node.id.clone(),
                    to: node.room.clone(),
                    kind: "belongs_to".to_string(),
                });
            }
        }

        // Build room list
        let rooms: Vec<RoomInfo> = rooms_map.into_iter()
            .map(|(name, count)| RoomInfo { name, count })
            .collect();

        Ok(GraphData { nodes, edges, rooms })
    }

    /// Classify a memory into a topic room by keyword matching.
    fn classify_to_room(&self, text: &str) -> String {
        let lower = text.to_lowercase();

        let room_keywords: Vec<(&str, Vec<&str>)> = vec![
            ("voice", vec!["voice", "speech", "stt", "tts", "whisper", "kokoro", "microphone", "audio", "transcri"]),
            ("agents", vec!["claude", "agent", "chat", "bridge", "acp", "mcp", "llm", "prompt"]),
            ("memory", vec!["memory", "eidetic", "knowledge", "graph", "recall", "embedding", "vector"]),
            ("architecture", vec!["rust", "swift", "backend", "frontend", "server", "api", "endpoint", "route"]),
            ("tools", vec!["gibber", "tool", "skill", "hook", "executor", "plugin"]),
            ("ui", vec!["sidebar", "button", "page", "view", "layout", "interface", "design", "rebrand"]),
            ("code", vec!["compile", "build", "binary", "package", "cargo", "swift build", "onnx"]),
            ("preferences", vec!["prefer", "local-first", "no cloud", "privacy", "zero api"]),
        ];

        let mut best_room = "general".to_string();
        let mut best_score = 0;

        for (room, keywords) in &room_keywords {
            let score: usize = keywords.iter()
                .filter(|kw| lower.contains(*kw))
                .count();
            if score > best_score {
                best_score = score;
                best_room = room.to_string();
            }
        }

        best_room
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

#[derive(serde::Serialize)]
pub struct GraphData {
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<GraphEdge>,
    pub rooms: Vec<RoomInfo>,
}

#[derive(serde::Serialize)]
pub struct GraphNode {
    pub id: String,
    pub kind: String,
    pub payload: String,
    pub alias: Option<String>,
    pub room: String,
}

#[derive(serde::Serialize)]
pub struct GraphEdge {
    pub from: String,
    pub to: String,
    pub kind: String,
}

#[derive(serde::Serialize)]
pub struct RoomInfo {
    pub name: String,
    pub count: usize,
}
