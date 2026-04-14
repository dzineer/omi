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
            .join(".omi")
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
