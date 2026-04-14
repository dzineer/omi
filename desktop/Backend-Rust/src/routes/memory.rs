use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use std::sync::Arc;

use crate::services::memory::MemoryService;

#[derive(Deserialize)]
pub struct SaveRequest {
    pub text: String,
    pub source: Option<String>,
    #[serde(default)]
    pub conversation: bool,
}

#[derive(Deserialize)]
pub struct QueryRequest {
    pub query: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    5
}

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

pub fn memory_routes() -> Router<Arc<MemoryService>> {
    Router::new()
        .route("/api/memory/save", post(save_memory))
        .route("/api/memory/query", post(query_memory))
        .route("/api/memory/status", get(memory_status))
}
