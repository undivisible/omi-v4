//! workers-rs I/O layer for the Memory & Currents group. Compiled only for
//! wasm32. Behaviour parity with `memory-sync.ts`, `memory-vectors.ts`,
//! `embeddings.ts`, `currents.ts`, `memory-projection.ts`, and the memory
//! routes in `routes.ts`.
//!
//! Deferred vector work: the TS enqueues `drainPendingEmbeddings` via
//! `executionCtx.waitUntil`. workers-rs `Router` handlers do not receive the
//! execution `Context`, so drains are awaited inline here — the vector state
//! converges identically; only the response-latency profile differs.

use base64::Engine as _;
use serde_json::{json, Value};
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::wasm_bindgen_futures::JsFuture;
use worker::{js_sys, Env, Request, Response, Result, RouteContext, Router};
use worker::{D1Database, D1PreparedStatement, D1Result};

use crate::auth::Auth;
use crate::channel_commands;
use crate::crypto_util::sha256_hex;
use crate::currents_refresh::{
    self, GeneratedDraft, MemoryLine, RefreshContext, RefreshState, REFRESH_BATCH_SIZE,
};
use crate::glue::{authenticate, error_json, json_to_i64, AuthOutcome};
use crate::managed_ai;
use crate::memory_log;
use crate::routes_memory;
use crate::worker_util::{changes, now_ms, secret_or_var as env_get, uuid_v4};
use worker::{Headers, Method, RequestInit};

use super::*;

// ---------------------------------------------------------------------------
// Route registration + cron hook
// ---------------------------------------------------------------------------

/// Register every Memory & Currents route onto the shared router (single hook
/// wired from `glue::fetch`).
pub fn register(router: Router<'_, ()>) -> Router<'_, ()> {
    router
        // memory-sync
        .post_async("/v1/memory/zkr-sync", handle_zkr_sync)
        .get_async("/v1/memory/log", handle_memory_log)
        // memory retrieval + CRUD
        .get_async("/v1/memory/retrieve", handle_retrieve)
        .post_async("/v1/memory/retrieve", handle_retrieve)
        .get_async("/v1/memory/semantic-search", handle_semantic_search)
        .get_async("/v1/memories", handle_memories_get)
        .post_async("/v1/memories", handle_memories_post)
        .post_async(
            "/v1/memory/sources/:sourceId/revisions",
            handle_source_revision,
        )
        .delete_async("/v1/memory/sources/:sourceId", handle_source_delete)
        .get_async("/v1/memory/daily-reviews", handle_daily_reviews_get)
        .post_async("/v1/memory/daily-reviews", handle_daily_reviews_post)
        // currents
        .post_async("/v1/currents/generate", handle_current_generate)
        .post_async("/v1/currents/candidates", handle_current_candidates)
        .post_async("/v1/currents/meeting-actions", handle_meeting_actions)
        .get_async("/v1/currents", handle_currents_list)
        .post_async("/v1/currents/refresh", handle_current_refresh)
        .post_async("/v1/currents/:id/feedback", handle_current_feedback)
        .post_async("/v1/currents/:id/accept", handle_current_accept)
        .post_async(
            "/v1/currents/executions/:id/approve",
            handle_execution_approve,
        )
        .post_async(
            "/v1/currents/executions/:id/receipts/:receiptId/claim",
            handle_receipt_claim,
        )
        .post_async(
            "/v1/currents/executions/:id/reject",
            handle_execution_reject,
        )
        .post_async(
            "/v1/currents/executions/:id/outcome",
            handle_execution_outcome,
        )
}

/// Scheduled cron slice: backfill claims missing vectors, then drain. Combine
/// this into the merged `#[event(scheduled)]` handler additively.
pub async fn cron_slice(env: &Env) {
    if backfill_claim_vectors(env, BACKFILL_BATCH_SIZE)
        .await
        .is_ok()
    {
        let _ = drain_pending_embeddings(env, DRAIN_BATCH_SIZE).await;
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

pub(crate) fn s(value: &str) -> JsValue {
    JsValue::from_str(value)
}

pub(crate) fn n(value: i64) -> JsValue {
    JsValue::from_f64(value as f64)
}

pub(crate) fn nullable_s(value: Option<&str>) -> JsValue {
    value.map(JsValue::from_str).unwrap_or(JsValue::NULL)
}

pub(crate) fn nullable_n(value: Option<i64>) -> JsValue {
    value
        .map(|v| JsValue::from_f64(v as f64))
        .unwrap_or(JsValue::NULL)
}

fn receipt_token() -> String {
    let mut b = [0u8; 32];
    let _ = getrandom::getrandom(&mut b);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
}

/// Read the request body as a JSON object (`object(await req.json())`): returns
/// `None` for invalid JSON, non-objects, arrays, or null.
async fn json_object(req: &mut Request) -> Option<Value> {
    req.json::<Value>().await.ok().filter(Value::is_object)
}

/// routes.ts / currents `text(value, limit)`: trimmed, non-empty, bounded.
fn trimmed(value: Option<&Value>, limit: usize) -> Option<String> {
    let s = value?.as_str()?;
    let t = s.trim();
    (!t.is_empty() && s.chars().count() <= limit).then(|| t.to_string())
}

/// Authenticate; on rejection return the short-circuit `Response`.
async fn require_auth(
    req: &Request,
    ctx: &RouteContext<()>,
) -> std::result::Result<Auth, Response> {
    match authenticate(req, ctx).await {
        AuthOutcome::Ok(auth) => Ok(auth),
        AuthOutcome::Reject(response) => Err(response),
    }
}

macro_rules! authed {
    ($req:expr, $ctx:expr) => {
        match require_auth(&$req, &$ctx).await {
            Ok(auth) => auth,
            Err(response) => return Ok(response),
        }
    };
}

pub(crate) async fn d1_first(
    db: &D1Database,
    sql: &str,
    binds: &[JsValue],
) -> Result<Option<Value>> {
    db.prepare(sql).bind(binds)?.first::<Value>(None).await
}

pub(crate) async fn d1_all(db: &D1Database, sql: &str, binds: &[JsValue]) -> Result<Vec<Value>> {
    db.prepare(sql).bind(binds)?.all().await?.results::<Value>()
}

pub(crate) async fn d1_run(db: &D1Database, sql: &str, binds: &[JsValue]) -> Result<D1Result> {
    db.prepare(sql).bind(binds)?.run().await
}

pub(crate) fn stmt(db: &D1Database, sql: &str, binds: &[JsValue]) -> Result<D1PreparedStatement> {
    db.prepare(sql).bind(binds)
}

pub(crate) fn str_field(row: &Value, key: &str) -> String {
    match row.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn opt_str_field(row: &Value, key: &str) -> Option<String> {
    match row.get(key) {
        Some(Value::Null) | None => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(other) => Some(other.to_string()),
    }
}

// ---------------------------------------------------------------------------
// Workers AI embeddings + Vectorize FFI
// ---------------------------------------------------------------------------

/// `embedTexts(env, texts)` via the native `Ai` binding.
async fn embed_texts(env: &Env, texts: &[String]) -> Option<Vec<Vec<f64>>> {
    if texts.is_empty() {
        return Some(Vec::new());
    }
    let ai = env.ai("AI").ok()?;
    let inputs = embedding_inputs(texts);
    let payload = json!({ "text": inputs });
    let result: Value = ai.run(EMBEDDING_MODEL, payload).await.ok()?;
    parse_embeddings(result.get("data")?, texts.len())
}

/// Thin wrapper around the bound `VectorizeIndex` JS object.
struct Vectorize(JsValue);

fn vectorize(env: &Env) -> Option<Vectorize> {
    let binding = js_sys::Reflect::get(env.as_ref(), &s("MEMORY_VECTORS")).ok()?;
    if binding.is_undefined() || binding.is_null() {
        None
    } else {
        Some(Vectorize(binding))
    }
}

impl Vectorize {
    async fn call(
        &self,
        method: &str,
        args: &js_sys::Array,
    ) -> std::result::Result<JsValue, JsValue> {
        let func = js_sys::Reflect::get(&self.0, &s(method))?.dyn_into::<js_sys::Function>()?;
        let promise = func.apply(&self.0, args)?.dyn_into::<js_sys::Promise>()?;
        JsFuture::from(promise).await
    }

    async fn upsert(&self, vectors: &Value) -> std::result::Result<(), JsValue> {
        let arg = serde_wasm_bindgen::to_value(vectors).map_err(JsValue::from)?;
        let args = js_sys::Array::of1(&arg);
        self.call("upsert", &args).await.map(|_| ())
    }

    async fn delete_by_ids(&self, ids: &[String]) -> std::result::Result<(), JsValue> {
        let arg = serde_wasm_bindgen::to_value(ids).map_err(JsValue::from)?;
        let args = js_sys::Array::of1(&arg);
        self.call("deleteByIds", &args).await.map(|_| ())
    }

    async fn query(&self, vector: &[f64], top_k: i64, uid: &str) -> Option<Vec<(String, f64)>> {
        let vec_arg = serde_wasm_bindgen::to_value(vector).ok()?;
        let options = json!({
            "topK": top_k,
            "filter": { "uid": uid },
            "returnValues": false,
            "returnMetadata": "none",
        });
        let opt_arg = serde_wasm_bindgen::to_value(&options).ok()?;
        let args = js_sys::Array::of2(&vec_arg, &opt_arg);
        let result = self.call("query", &args).await.ok()?;
        let value: Value = serde_wasm_bindgen::from_value(result).ok()?;
        let matches = value.get("matches").and_then(Value::as_array)?;
        Some(
            matches
                .iter()
                .filter_map(|m| {
                    let id = m
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())?;
                    let score = m.get("score").and_then(Value::as_f64).unwrap_or(0.0);
                    Some((id.to_string(), score))
                })
                .collect(),
        )
    }
}

// ---------------------------------------------------------------------------
// pending_embeddings enqueue / drain / backfill (memory-vectors.ts)
// ---------------------------------------------------------------------------

const ENQUEUE_SQL: &str = "INSERT INTO pending_embeddings (uid, claim_id, enqueued_at)\n     VALUES (?1, ?2, ?3)\n     ON CONFLICT(uid, claim_id) DO UPDATE SET\n       enqueued_at = excluded.enqueued_at, attempts = 0, last_error = NULL";

fn enqueue_statements(
    db: &D1Database,
    uid: &str,
    claim_ids: &[String],
    now: i64,
) -> Result<Vec<D1PreparedStatement>> {
    claim_ids
        .iter()
        .map(|claim_id| stmt(db, ENQUEUE_SQL, &[s(uid), s(claim_id), n(now)]))
        .collect()
}

const DRAIN_LOOKUP_SQL: &str = "SELECT id, uid, content, subject, predicate, recorded_at,\n                (status = 'accepted' AND retracted_at IS NULL\n                 AND (zkr_tier IS NULL OR zkr_tier != 'archive')\n                 AND (zkr_processing_state IS NULL OR zkr_processing_state = 'processed')) AS eligible\n         FROM memory_claims WHERE id = ?1 AND uid = ?2";

fn claim_row_from(value: &Value) -> Option<ClaimRow> {
    Some(ClaimRow {
        id: value.get("id").and_then(Value::as_str)?.to_string(),
        uid: value.get("uid").and_then(Value::as_str)?.to_string(),
        content: str_field(value, "content"),
        subject: opt_str_field(value, "subject"),
        predicate: opt_str_field(value, "predicate"),
        recorded_at: value.get("recorded_at").and_then(json_to_i64).unwrap_or(0),
        eligible: value.get("eligible").and_then(json_to_i64).unwrap_or(0),
    })
}

async fn drain_pending_embeddings(env: &Env, limit: i64) -> Result<()> {
    let Some(index) = vectorize(env) else {
        return Ok(());
    };
    let db = env.d1("DB")?;
    let pending_rows = d1_all(
        &db,
        "SELECT uid, claim_id FROM pending_embeddings WHERE attempts < ?1 ORDER BY enqueued_at, claim_id LIMIT ?2",
        &[n(MAXIMUM_ATTEMPTS), n(limit)],
    )
    .await?;
    let rows: Vec<PendingRow> = pending_rows
        .iter()
        .filter_map(|row| {
            Some(PendingRow {
                uid: row.get("uid").and_then(Value::as_str)?.to_string(),
                claim_id: row.get("claim_id").and_then(Value::as_str)?.to_string(),
            })
        })
        .collect();
    if rows.is_empty() {
        return Ok(());
    }
    let lookup_stmts: Vec<D1PreparedStatement> = rows
        .iter()
        .map(|row| stmt(&db, DRAIN_LOOKUP_SQL, &[s(&row.claim_id), s(&row.uid)]))
        .collect::<Result<Vec<_>>>()?;
    let lookup_results = db.batch(lookup_stmts).await?;
    let lookups: Vec<Option<ClaimRow>> = lookup_results
        .iter()
        .map(|result| {
            result
                .results::<Value>()
                .ok()
                .and_then(|rows| rows.into_iter().next())
                .and_then(|v| claim_row_from(&v))
        })
        .collect();
    let (upserts, deletions) = partition_drain(&rows, &lookups);

    let mut settled: Vec<PendingRow> = Vec::new();
    let mut failed: Vec<(PendingRow, String)> = Vec::new();

    if !deletions.is_empty() {
        let ids: Vec<String> = deletions.iter().map(|d| d.claim_id.clone()).collect();
        match index.delete_by_ids(&ids).await {
            Ok(()) => settled.extend(deletions.iter().cloned()),
            Err(err) => {
                let msg = format!("{err:?}");
                failed.extend(deletions.iter().map(|d| (d.clone(), msg.clone())));
            }
        }
    }

    if !upserts.is_empty() {
        let upsert_rows: Vec<PendingRow> = upserts
            .iter()
            .map(|c| PendingRow {
                uid: c.uid.clone(),
                claim_id: c.id.clone(),
            })
            .collect();
        let texts: Vec<String> = upserts
            .iter()
            .map(|c| claim_text(c.subject.as_deref(), c.predicate.as_deref(), &c.content))
            .collect();
        match embed_texts(env, &texts).await {
            None => failed.extend(
                upsert_rows
                    .iter()
                    .map(|r| (r.clone(), "Embedding failed".to_string())),
            ),
            Some(vectors) => {
                let payload: Vec<Value> = upserts
                    .iter()
                    .enumerate()
                    .map(|(i, claim)| {
                        json!({
                            "id": claim.id,
                            "values": vectors.get(i).cloned().unwrap_or_default(),
                            "metadata": {
                                "uid": claim.uid,
                                "claimId": claim.id,
                                "kind": "claim",
                                "capturedAt": claim.recorded_at,
                            },
                        })
                    })
                    .collect();
                match index.upsert(&Value::Array(payload)).await {
                    Ok(()) => settled.extend(upsert_rows.iter().cloned()),
                    Err(err) => {
                        let msg = format!("{err:?}");
                        failed.extend(upsert_rows.iter().map(|r| (r.clone(), msg.clone())));
                    }
                }
            }
        }
    }

    let now = now_ms();
    let mut statements: Vec<D1PreparedStatement> = Vec::new();
    for row in &settled {
        statements.push(stmt(
            &db,
            "DELETE FROM pending_embeddings WHERE uid = ?1 AND claim_id = ?2",
            &[s(&row.uid), s(&row.claim_id)],
        )?);
        statements.push(stmt(
            &db,
            "UPDATE memory_claims SET vector_indexed_at = ?1 WHERE id = ?2 AND uid = ?3",
            &[n(now), s(&row.claim_id), s(&row.uid)],
        )?);
    }
    for (row, error) in &failed {
        let truncated: String = error.chars().take(500).collect();
        statements.push(stmt(
            &db,
            "UPDATE pending_embeddings SET attempts = attempts + 1, last_error = ?1 WHERE uid = ?2 AND claim_id = ?3",
            &[s(&truncated), s(&row.uid), s(&row.claim_id)],
        )?);
    }
    if !statements.is_empty() {
        db.batch(statements).await?;
    }
    Ok(())
}

pub(crate) async fn delete_claim_vectors(env: &Env, claim_ids: &[String]) {
    let Some(index) = vectorize(env) else {
        return;
    };
    for ids in claim_ids.chunks(DELETE_CHUNK_SIZE) {
        let _ = index.delete_by_ids(ids).await;
    }
}

async fn backfill_claim_vectors(env: &Env, limit: i64) -> Result<i64> {
    if vectorize(env).is_none() {
        return Ok(0);
    }
    let db = env.d1("DB")?;
    let rows = d1_all(
        &db,
        "SELECT c.id, c.uid FROM memory_claims c\n     WHERE c.vector_indexed_at IS NULL\n       AND NOT EXISTS (\n         SELECT 1 FROM pending_embeddings p\n         WHERE p.uid = c.uid AND p.claim_id = c.id\n       )\n     ORDER BY c.recorded_at, c.id LIMIT ?1",
        &[n(limit)],
    )
    .await?;
    if rows.is_empty() {
        return Ok(0);
    }
    let now = now_ms();
    let mut statements = Vec::new();
    for row in &rows {
        let uid = row.get("uid").and_then(Value::as_str).unwrap_or_default();
        let id = row.get("id").and_then(Value::as_str).unwrap_or_default();
        statements.extend(enqueue_statements(&db, uid, &[id.to_string()], now)?);
    }
    db.batch(statements).await?;
    Ok(rows.len() as i64)
}

/// Direct vector search + D1 re-check (`searchMemoryClaims`).
pub(crate) async fn search_memory_claims(
    env: &Env,
    uid: &str,
    query: &str,
    top_k: i64,
) -> Result<Vec<Value>> {
    let Some(index) = vectorize(env) else {
        return Ok(Vec::new());
    };
    let Some(vectors) = embed_texts(env, &[query.to_string()]).await else {
        return Ok(Vec::new());
    };
    let Some(vector) = vectors.into_iter().next() else {
        return Ok(Vec::new());
    };
    let Some(matches) = index.query(&vector, top_k, uid).await else {
        return Ok(Vec::new());
    };
    if matches.is_empty() {
        return Ok(Vec::new());
    }
    let db = env.d1("DB")?;
    let now = now_ms();
    let lookup_stmts: Vec<D1PreparedStatement> = matches
        .iter()
        .map(|(id, _)| {
            stmt(
                &db,
                "SELECT id, content FROM memory_claims\n         WHERE id = ?1 AND uid = ?2\n           AND status = 'accepted' AND retracted_at IS NULL\n           AND (valid_from IS NULL OR valid_from <= ?3)\n           AND (valid_to IS NULL OR valid_to > ?3)\n           AND (recorded_until IS NULL OR recorded_until > ?3)\n           AND (zkr_tier IS NULL OR zkr_tier != 'archive')\n           AND (zkr_processing_state IS NULL OR zkr_processing_state = 'processed')",
                &[s(id), s(uid), n(now)],
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let lookups = db.batch(lookup_stmts).await?;
    let mut items = Vec::new();
    for ((_, score), result) in matches.iter().zip(lookups.iter()) {
        if let Some(claim) = result.results::<Value>()?.into_iter().next() {
            items.push(json!({
                "id": str_field(&claim, "id"),
                "content": str_field(&claim, "content"),
                "score": score,
            }));
        }
    }
    Ok(items)
}

/// Port of `memoryContextFor` (memory-vectors.ts). Vector-searches the user's
/// synced memory claims and folds the top matches into the `Relevant synced
/// memory` context block, capped at `CONTEXT_CHARACTER_CAP`. Returns `None` when
/// Vectorize/AI is unbound, there are no matches, or any step fails — matching
/// the TS `try/catch → null` contract so callers degrade gracefully.
pub async fn memory_context_for(env: &Env, uid: &str, query: &str) -> Option<String> {
    let db = env.d1("DB").ok()?;
    let profiles = list_profile_memories(&db, uid, 24).await.ok()?;
    let items = search_memory_claims(env, uid, query, 8).await.ok()?;
    let contents: Vec<String> = items
        .iter()
        .map(|item| str_field(item, "content"))
        .collect();
    super::build_memory_context_with_profile(&profiles, &contents, super::CONTEXT_CHARACTER_CAP)
}

// ---------------------------------------------------------------------------
// memory-projection.ts
// ---------------------------------------------------------------------------

mod projection_sql;

async fn project_zkr_memory(db: &D1Database, uid: &str, _replica_id: &str) -> Result<()> {
    let state = d1_first(
        db,
        "SELECT sequence FROM memory_projection_state WHERE uid = ?1",
        &[s(uid)],
    )
    .await?;
    let mut cursor = state
        .as_ref()
        .and_then(|row| row.get("sequence"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    loop {
        let rows = d1_all(db, memory_log::READ_SQL, &[s(uid), n(cursor), n(500)]).await?;
        if rows.is_empty() {
            break;
        }
        let mut statements = Vec::new();
        for row in &rows {
            let sequence = row.get("sequence").and_then(json_to_i64).unwrap_or(cursor);
            let kind = str_field(row, "record_kind");
            let id = str_field(row, "record_id");
            let payload_text = str_field(row, "payload");
            let payload: Value = serde_json::from_str(&payload_text)
                .map_err(|_| worker::Error::RustError("Invalid memory log payload".into()))?;
            let record = SyncRecord {
                kind: kind.clone(),
                record: payload,
            };
            let deleted_at = if kind == "deletion" {
                deletion_target(&record).map(|target| target.deleted_at)
            } else {
                match record.record.as_object() {
                    Some(body) if kind == "source" => body
                        .get("source")
                        .and_then(Value::as_object)
                        .and_then(|source| source.get("deleted_at"))
                        .and_then(json_to_i64),
                    Some(body) => body.get("deleted_at").and_then(json_to_i64),
                    None => None,
                }
            };
            statements.push(stmt(
                db,
                "INSERT INTO memory_records (uid, record_kind, record_id, payload, sequence, recorded_at, deleted_at)\n             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)\n             ON CONFLICT(uid, record_kind, record_id) DO UPDATE SET\n               payload = excluded.payload, sequence = excluded.sequence, recorded_at = excluded.recorded_at,\n               deleted_at = COALESCE(excluded.deleted_at, memory_records.deleted_at)\n             WHERE excluded.sequence >= memory_records.sequence",
                &[
                    s(uid),
                    s(&kind),
                    s(&id),
                    s(&payload_text),
                    n(sequence),
                    n(row.get("recorded_at").and_then(json_to_i64).unwrap_or(0)),
                    nullable_n(deleted_at),
                ],
            )?);
            if let Some(target) = deletion_target(&record) {
                statements.push(stmt(
                    db,
                    "UPDATE memory_records SET deleted_at = ?1, sequence = ?2\n               WHERE uid = ?3 AND record_kind = ?4 AND record_id = ?5 AND sequence <= ?2",
                    &[n(target.deleted_at), n(sequence), s(uid), s(&target.kind), s(&target.id)],
                )?);
            }
            cursor = sequence;
        }
        db.batch(statements).await?;
    }
    let sql_statements = projection_sql::projection_statements();
    let mut statements = Vec::with_capacity(sql_statements.len());
    for sql in &sql_statements {
        statements.push(stmt(db, sql, &[s(uid)])?);
    }
    db.batch(statements).await?;
    d1_run(
        db,
        "INSERT INTO memory_projection_state (uid, sequence, projected_at)\n       VALUES (?1, ?2, ?3)\n       ON CONFLICT(uid) DO UPDATE SET\n         sequence = MAX(memory_projection_state.sequence, excluded.sequence),\n         projected_at = excluded.projected_at",
        &[s(uid), n(cursor), n(now_ms())],
    )
    .await?;
    Ok(())
}

pub(crate) async fn ensure_projected(db: &D1Database, uid: &str) -> Result<()> {
    let head = d1_first(db, memory_log::HEAD_SQL, &[s(uid)]).await?;
    let state = d1_first(
        db,
        "SELECT sequence FROM memory_projection_state WHERE uid = ?1",
        &[s(uid)],
    )
    .await?;
    let head = head
        .as_ref()
        .and_then(|row| row.get("sequence"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    let projected = state
        .as_ref()
        .and_then(|row| row.get("sequence"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    if head > projected {
        project_zkr_memory(db, uid, "").await?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// memory-sync.ts handler
// ---------------------------------------------------------------------------

fn record_envelope(record: &SyncRecord) -> Value {
    json!({ "kind": record.kind, "record": record.record })
}

async fn apply_commit(
    db: &D1Database,
    uid: &str,
    replica_id: &str,
    commit: &SyncCommit,
) -> Result<(String, Vec<String>)> {
    let existing = d1_first(
        db,
        "SELECT applied_at FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
        &[s(uid), s(replica_id), n(commit.sequence)],
    )
    .await?;
    let already_applied = existing
        .as_ref()
        .and_then(|r| r.get("applied_at"))
        .map(|v| !v.is_null())
        .unwrap_or(false);
    if already_applied {
        project_zkr_memory(db, uid, replica_id).await?;
        return Ok(("replayed".to_string(), Vec::new()));
    }
    let event_rows = d1_all(
        db,
        "SELECT event_index, payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 ORDER BY event_index",
        &[s(uid), s(replica_id), n(commit.sequence)],
    )
    .await?;
    if event_rows.len() as i64 != commit.event_count
        || event_rows
            .iter()
            .enumerate()
            .any(|(index, row)| row.get("event_index").and_then(json_to_i64) != Some(index as i64))
    {
        return Ok(("replayed".to_string(), Vec::new()));
    }
    let records: Vec<SyncRecord> = event_rows
        .iter()
        .filter_map(|row| {
            let payload = row.get("payload").and_then(Value::as_str)?;
            let value: Value = serde_json::from_str(payload).ok()?;
            Some(SyncRecord {
                kind: value.get("kind").and_then(Value::as_str)?.to_string(),
                record: value.get("record").cloned()?,
            })
        })
        .collect();
    if records.len() != event_rows.len() {
        return Err(worker::Error::RustError("Invalid staged zkr record".into()));
    }
    let mut identities = Vec::with_capacity(records.len());
    for record in &records {
        match record_identity(record) {
            Some(identity) => identities.push(identity),
            None => return Err(worker::Error::RustError("Invalid staged zkr record".into())),
        }
    }
    let now = now_ms();
    let mut statements: Vec<D1PreparedStatement> = Vec::new();
    for (record, identity) in records.iter().zip(identities.iter()) {
        statements.push(stmt(
            db,
            memory_log::APPEND_SQL,
            &[
                s(uid),
                s(replica_id),
                s(&identity.kind),
                s(&identity.id),
                s(&canonical_json(&record.record)),
                n(commit.recorded_at),
                n(now),
            ],
        )?);
    }
    db.batch(statements).await?;
    project_zkr_memory(db, uid, replica_id).await?;
    d1_run(
        db,
        "UPDATE zkr_sync_commits SET applied_at = ?1 WHERE uid = ?2 AND replica_id = ?3 AND sequence = ?4 AND applied_at IS NULL",
        &[n(now), s(uid), s(replica_id), n(commit.sequence)],
    )
    .await?;
    Ok((
        "applied".to_string(),
        touched_claim_ids(uid, replica_id, &records),
    ))
}

async fn handle_zkr_sync(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let uid = auth.uid;

    let Some(body) = json_object(&mut req).await else {
        return error_json("Invalid zkr sync payload", 400);
    };
    let replica_id = trimmed(body.get("replica_id"), 200);
    let export_ok = body.get("export_format").and_then(Value::as_i64) == Some(1);
    let commits_arr = body.get("commits").and_then(Value::as_array).cloned();
    let (Some(replica_id), true, Some(commits_arr)) = (replica_id, export_ok, commits_arr) else {
        return error_json("Invalid zkr sync payload", 400);
    };

    let mut commits = Vec::with_capacity(commits_arr.len());
    for commit in &commits_arr {
        match parse_commit(commit, &uid) {
            Some(parsed) => commits.push(parsed),
            None => return error_json("Invalid or foreign zkr scope", 400),
        }
    }

    let mut statuses: Vec<Value> = Vec::new();
    let mut pending_claim_ids: Vec<String> = Vec::new();

    for commit in &commits {
        let existing = d1_first(
            &db,
            "SELECT recorded_at, event_count, applied_at FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
            &[s(&uid), s(&replica_id), n(commit.sequence)],
        )
        .await?;
        if let Some(existing) = &existing {
            let recorded = existing.get("recorded_at").and_then(json_to_i64);
            let count = existing.get("event_count").and_then(json_to_i64);
            if recorded != Some(commit.recorded_at) || count != Some(commit.event_count) {
                return error_json("Conflicting zkr commit replay", 409);
            }
        }

        let payloads: Vec<String> = commit
            .records
            .iter()
            .map(|record| canonical_json(&record_envelope(record)))
            .collect();
        let indexes: Vec<i64> = (0..payloads.len() as i64)
            .map(|offset| commit.first_event_index + offset)
            .collect();

        let existing_event_stmts: Vec<D1PreparedStatement> = indexes
            .iter()
            .map(|index| {
                stmt(
                    &db,
                    "SELECT payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 AND event_index = ?4",
                    &[s(&uid), s(&replica_id), n(commit.sequence), n(*index)],
                )
            })
            .collect::<Result<Vec<_>>>()?;
        let existing_events = db.batch(existing_event_stmts).await?;
        for (index, result) in existing_events.iter().enumerate() {
            if let Some(row) = result.results::<Value>()?.into_iter().next() {
                if let Some(payload) = row.get("payload").and_then(Value::as_str) {
                    if payload != payloads[index] {
                        return error_json("Conflicting zkr event replay", 409);
                    }
                }
            }
        }

        let mut insert_stmts: Vec<D1PreparedStatement> = Vec::new();
        insert_stmts.push(stmt(
            &db,
            "INSERT OR IGNORE INTO zkr_sync_commits\n             (uid, replica_id, sequence, recorded_at, event_count)\n           VALUES (?1, ?2, ?3, ?4, ?5)",
            &[
                s(&uid),
                s(&replica_id),
                n(commit.sequence),
                n(commit.recorded_at),
                n(commit.event_count),
            ],
        )?);
        for (index, payload) in payloads.iter().enumerate() {
            insert_stmts.push(stmt(
                &db,
                "INSERT OR IGNORE INTO zkr_sync_events\n               (uid, replica_id, commit_sequence, event_index, payload)\n             VALUES (?1, ?2, ?3, ?4, ?5)",
                &[
                    s(&uid),
                    s(&replica_id),
                    n(commit.sequence),
                    n(indexes[index]),
                    s(payload),
                ],
            )?);
        }
        db.batch(insert_stmts).await?;

        let persisted_commit = d1_first(
            &db,
            "SELECT recorded_at, event_count FROM zkr_sync_commits WHERE uid = ?1 AND replica_id = ?2 AND sequence = ?3",
            &[s(&uid), s(&replica_id), n(commit.sequence)],
        )
        .await?;
        let persisted_events = d1_all(
            &db,
            "SELECT event_index, payload FROM zkr_sync_events WHERE uid = ?1 AND replica_id = ?2 AND commit_sequence = ?3 ORDER BY event_index",
            &[s(&uid), s(&replica_id), n(commit.sequence)],
        )
        .await?;
        let mut persisted_by_index: std::collections::HashMap<i64, String> =
            std::collections::HashMap::new();
        for row in &persisted_events {
            if let (Some(idx), Some(payload)) = (
                row.get("event_index").and_then(json_to_i64),
                row.get("payload").and_then(Value::as_str),
            ) {
                persisted_by_index.insert(idx, payload.to_string());
            }
        }
        let commit_mismatch = persisted_commit
            .as_ref()
            .and_then(|r| r.get("recorded_at"))
            .and_then(json_to_i64)
            != Some(commit.recorded_at)
            || persisted_commit
                .as_ref()
                .and_then(|r| r.get("event_count"))
                .and_then(json_to_i64)
                != Some(commit.event_count)
            || indexes.iter().enumerate().any(|(index, event_index)| {
                persisted_by_index.get(event_index).map(String::as_str) != Some(&payloads[index])
            });
        if commit_mismatch {
            return error_json("Conflicting zkr commit replay", 409);
        }
        if persisted_events.len() as i64 != commit.event_count {
            statuses.push(json!({ "sequence": commit.sequence, "status": "staged" }));
            continue;
        }
        let (status, claim_ids) = apply_commit(&db, &uid, &replica_id, commit).await?;
        for claim_id in claim_ids {
            if !pending_claim_ids.contains(&claim_id) {
                pending_claim_ids.push(claim_id);
            }
        }
        statuses.push(json!({ "sequence": commit.sequence, "status": status }));
    }

    if !pending_claim_ids.is_empty() {
        let now = now_ms();
        let statements = enqueue_statements(&db, &uid, &pending_claim_ids, now)?;
        db.batch(statements).await?;
        drain_pending_embeddings(&ctx.env, DRAIN_BATCH_SIZE).await?;
    }

    Response::from_json(&json!({ "replica_id": replica_id, "commits": statuses }))
}

async fn handle_memory_log(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let url = req.url()?;
    let param = |key: &str| {
        url.query_pairs()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.to_string())
    };
    let Some(cursor) = memory_log::validate_cursor(
        param("after").as_deref(),
        param("limit").as_deref(),
        param("replica_id").as_deref(),
    ) else {
        return error_json("Invalid memory log cursor", 400);
    };
    let db = ctx.env.d1("DB")?;
    let rows = d1_all(
        &db,
        memory_log::READ_SQL,
        &[s(&auth.uid), n(cursor.after), n(cursor.limit)],
    )
    .await?;
    let records = rows
        .into_iter()
        .map(|row| {
            let payload = serde_json::from_str::<Value>(&str_field(&row, "payload"))
                .map_err(|_| worker::Error::RustError("Invalid memory log payload".into()))?;
            Ok(json!({
                "sequence": row.get("sequence").and_then(json_to_i64).unwrap_or(0),
                "origin_replica": str_field(&row, "origin_replica"),
                "record_kind": str_field(&row, "record_kind"),
                "record_id": str_field(&row, "record_id"),
                "payload": payload,
                "recorded_at": row.get("recorded_at").and_then(json_to_i64).unwrap_or(0),
                "appended_at": row.get("appended_at").and_then(json_to_i64).unwrap_or(0),
            }))
        })
        .collect::<Result<Vec<_>>>()?;
    let head = d1_first(&db, memory_log::HEAD_SQL, &[s(&auth.uid)])
        .await?
        .as_ref()
        .and_then(|row| row.get("sequence"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    if let Some(replica_id) = cursor.replica_id {
        d1_run(
            &db,
            memory_log::CURSOR_SQL,
            &[s(&auth.uid), s(&replica_id), n(cursor.after), n(now_ms())],
        )
        .await?;
    }
    Response::from_json(&memory_log::page_envelope(records, cursor.after, head))
}

// ---------------------------------------------------------------------------
// memory retrieval routes (routes.ts)
// ---------------------------------------------------------------------------

async fn handle_retrieve(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;

    let is_post = req.method() == worker::Method::Post;
    let body = if is_post {
        json_object(&mut req).await
    } else {
        None
    };
    let url = req.url()?;
    let query_param = |key: &str| {
        url.query_pairs()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.to_string())
    };
    let query_value = body
        .as_ref()
        .and_then(|b| b.get("query").cloned())
        .or_else(|| query_param("q").map(Value::from));
    let query = trimmed(query_value.as_ref(), 500);
    let limit = body
        .as_ref()
        .and_then(|b| b.get("limit").and_then(json_to_i64))
        .or_else(|| query_param("limit").and_then(|v| v.parse::<i64>().ok()))
        .unwrap_or(12);
    let Some(query) = query else {
        return error_json("Invalid retrieval", 400);
    };
    if !(1..=50).contains(&limit) {
        return error_json("Invalid retrieval", 400);
    }
    Response::from_json(&retrieve_cited_memory(&db, &auth.uid, &query, limit).await?)
}

/// Port of `retrieveCitedMemory` (memory-read.ts): the one keyword retrieval
/// shared by the first-party `/v1` route, the public API and the MCP server.
pub(crate) async fn retrieve_cited_memory(
    db: &D1Database,
    uid: &str,
    query: &str,
    limit: i64,
) -> Result<Value> {
    let matcher = retrieve_match(query);
    let now = now_ms();
    let candidates = d1_all(
        db,
        "SELECT c.id, c.content, bm25(memory_claims_fts) AS score\n     FROM memory_claims_fts\n     JOIN memory_claims c ON c.id = memory_claims_fts.id AND c.uid = memory_claims_fts.uid\n     WHERE memory_claims_fts.uid = ?1 AND memory_claims_fts MATCH ?2\n       AND c.status = 'accepted' AND c.retracted_at IS NULL\n       AND (c.valid_from IS NULL OR c.valid_from <= ?4)\n       AND (c.valid_to IS NULL OR c.valid_to > ?4)\n       AND (c.recorded_until IS NULL OR c.recorded_until > ?4)\n       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')\n       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')\n     ORDER BY score, c.recorded_at DESC LIMIT ?3",
        &[s(uid), s(&matcher), n(limit), n(now)],
    )
    .await?;

    let mut items: Vec<Value> = Vec::new();
    if !candidates.is_empty() {
        let citation_stmts: Vec<D1PreparedStatement> = candidates
            .iter()
            .map(|row| {
                stmt(
                    db,
                    "SELECT ce.evidence_id FROM memory_claim_evidence ce\n           JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid\n           JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n           JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n           WHERE ce.claim_id = ?1 AND ce.uid = ?2 AND ce.relation = 'supports'\n             AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL",
                    &[s(&str_field(row, "id")), s(uid)],
                )
            })
            .collect::<Result<Vec<_>>>()?;
        let citations = db.batch(citation_stmts).await?;
        for (index, row) in candidates.iter().enumerate() {
            let evidence_ids: Vec<String> = citations[index]
                .results::<Value>()?
                .iter()
                .map(|e| str_field(e, "evidence_id"))
                .collect();
            if !evidence_ids.is_empty() {
                items.push(json!({
                    "memory": { "kind": "claim", "id": str_field(row, "id") },
                    "excerpt": str_field(row, "content"),
                    "relevance_basis_points": relevance_basis_points(index),
                    "evidence_ids": evidence_ids,
                }));
            }
        }
    }
    let gaps = if items.is_empty() {
        json!(["No cited memory matched the query."])
    } else {
        json!([])
    };
    Ok(json!({ "query": query, "items": items, "gaps": gaps }))
}

async fn handle_semantic_search(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let url = req.url()?;
    let query = url
        .query_pairs()
        .find(|(k, _)| k == "q")
        .map(|(_, v)| Value::from(v.to_string()));
    let query = trimmed(query.as_ref(), 500);
    let limit = url
        .query_pairs()
        .find(|(k, _)| k == "limit")
        .and_then(|(_, v)| v.parse::<i64>().ok())
        .unwrap_or(8);
    let Some(query) = query else {
        return error_json("Invalid retrieval", 400);
    };
    if !(1..=20).contains(&limit) {
        return error_json("Invalid retrieval", 400);
    }
    let items = search_memory_claims(&ctx.env, &auth.uid, &query, limit).await?;
    Response::from_json(&json!({ "query": query, "items": items }))
}

async fn handle_memories_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    Response::from_json(&json!({ "memories": list_profile_memories(&db, &auth.uid, 100).await? }))
}

/// Port of `listProfileMemories` (memory-read.ts).
pub(crate) async fn list_profile_memories(
    db: &D1Database,
    uid: &str,
    limit: usize,
) -> Result<Vec<Value>> {
    let now = now_ms();
    let rows = d1_all(
        db,
        "SELECT p.id, p.profile_key, c.value, c.valid_from, c.valid_to, c.recorded_at, p.updated_at,\n            p.profile_kind, p.status, s.kind AS source, e.id AS evidence_id,\n            e.source_revision_id, e.quote, e.locator, s.id AS source_id\n     FROM memory_profile_entries p\n     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid\n     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid\n     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     WHERE p.uid = ?1 AND p.status != 'archived' AND c.status = 'accepted' AND c.retracted_at IS NULL\n       AND (c.valid_from IS NULL OR c.valid_from <= ?2)\n       AND (c.valid_to IS NULL OR c.valid_to > ?2)\n       AND (c.recorded_until IS NULL OR c.recorded_until > ?2)\n       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')\n       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')\n       AND ce.relation = 'supports' AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL\n     ORDER BY p.updated_at DESC LIMIT 500",
        &[s(uid), n(now)],
    )
    .await?;

    let mut order: Vec<String> = Vec::new();
    let mut indexed: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for row in &rows {
        let id = str_field(row, "id");
        let evidence = json!({
            "id": str_field(row, "evidence_id"),
            "sourceId": str_field(row, "source_id"),
            "sourceRevisionId": str_field(row, "source_revision_id"),
            "quote": str_field(row, "quote"),
            "locator": parse_locator(row.get("locator")),
        });
        if let Some(existing) = indexed.get_mut(&id) {
            if let Some(arr) = existing.get_mut("evidence").and_then(Value::as_array_mut) {
                arr.push(evidence);
            }
            continue;
        }
        order.push(id.clone());
        indexed.insert(
            id.clone(),
            json!({
                "id": id,
                "profileKey": row.get("profile_key").cloned().unwrap_or_else(|| Value::String(id.clone())),
                "content": str_field(row, "value"),
                "source": str_field(row, "source"),
                "evidence": [evidence],
                "profileKind": row.get("profile_kind").cloned().unwrap_or(Value::Null),
                "status": row.get("status").cloned().unwrap_or(Value::Null),
                "validFrom": row.get("valid_from").and_then(json_to_i64),
                "validTo": row.get("valid_to").and_then(json_to_i64),
                "createdAt": row.get("recorded_at").and_then(json_to_i64).unwrap_or(0),
                "updatedAt": row.get("updated_at").and_then(json_to_i64).unwrap_or(0),
            }),
        );
    }
    Ok(order
        .into_iter()
        .take(limit)
        .filter_map(|id| indexed.remove(&id))
        .collect())
}

pub(crate) fn parse_locator(value: Option<&Value>) -> Value {
    match value {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

async fn handle_memories_post(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let body_ref = body.as_ref();

    let content = trimmed(body_ref.and_then(|b| b.get("content")), 20_000);
    let source = trimmed(body_ref.and_then(|b| b.get("source")), 100);
    let subject = trimmed(body_ref.and_then(|b| b.get("subject")), 200)
        .unwrap_or_else(|| "person".to_string());
    let predicate = trimmed(body_ref.and_then(|b| b.get("predicate")), 200)
        .unwrap_or_else(|| "remembers".to_string());
    let profile_key = trimmed(body_ref.and_then(|b| b.get("profileKey")), 200)
        .unwrap_or_else(|| predicate.clone());
    let profile_kind = body_ref
        .and_then(|b| b.get("profileKind"))
        .and_then(Value::as_str)
        .unwrap_or("current")
        .to_string();
    // TS: `body.validFrom === undefined ? Date.now() : Number(body.validFrom)`
    // — only absent means now; explicit null coerces to 0 (and is rejected).
    let valid_from = match body_ref.and_then(|b| b.get("validFrom")) {
        None => Some(now_ms()),
        Some(Value::Null) => Some(0),
        Some(v) => json_to_i64(v),
    };
    let valid_to = match body_ref.and_then(|b| b.get("validTo")) {
        None | Some(Value::Null) => None,
        Some(v) => Some(json_to_i64(v)),
    };
    let evidence_val = body_ref.and_then(|b| b.get("evidence"));
    let evidence_bad = matches!(evidence_val, Some(v) if !v.is_array());

    let valid_from_ok = valid_from.filter(|v| *v > 0);
    let valid_to_bad = matches!(&valid_to, Some(None)) // present but non-numeric
        || matches!((&valid_to, &valid_from_ok), (Some(Some(to)), Some(from)) if to < from);

    let (Some(content), Some(source), Some(valid_from), false, false) = (
        content,
        source.filter(|src| SOURCE_KINDS.contains(&src.as_str())),
        valid_from_ok,
        !(profile_kind == "stable" || profile_kind == "current"),
        evidence_bad || valid_to_bad,
    ) else {
        return error_json("Invalid memory", 400);
    };
    let valid_to = valid_to.flatten();

    let id = uuid_v4();
    let source_id = uuid_v4();
    let revision_id = uuid_v4();
    let evidence_id = uuid_v4();
    let claim_id = uuid_v4();
    let now = now_ms();
    let content_hash = sha256_hex(&content);
    let evidence_json =
        serde_json::to_string(evidence_val.unwrap_or(&json!([]))).unwrap_or("[]".into());
    let payload_json = json!({ "content": content }).to_string();

    let mut statements = vec![
        stmt(
            &db,
            "INSERT INTO memory_sources (id, uid, kind, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)",
            &[s(&source_id), s(&auth.uid), s(&source), n(now)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?6)",
            &[s(&revision_id), s(&source_id), s(&auth.uid), s(&content_hash), s(&payload_json), n(now)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, locator, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            &[s(&evidence_id), s(&auth.uid), s(&revision_id), s(&content), s(&evidence_json), n(now)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_claims\n         (id, uid, content, subject, predicate, value, valid_from, valid_to, recorded_at)\n       VALUES (?1, ?2, ?3, ?4, ?5, ?3, ?6, ?7, ?8)",
            &[s(&claim_id), s(&auth.uid), s(&content), s(&subject), s(&predicate), n(valid_from), nullable_n(valid_to), n(now)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)\n       VALUES (?1, ?2, ?3, ?4, ?5, ?3)",
            &[s(&claim_id), s(&auth.uid), s(&content), s(&subject), s(&predicate)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation, confidence_basis_points) VALUES (?1, ?2, ?3, 'supports', 10000)",
            &[s(&auth.uid), s(&claim_id), s(&evidence_id)],
        )?,
        stmt(
            &db,
            "INSERT INTO memory_profile_entries\n         (id, uid, claim_id, profile_kind, profile_key, profile_value, created_at, updated_at)\n       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            &[s(&id), s(&auth.uid), s(&claim_id), s(&profile_kind), s(&profile_key), s(&content), n(now)],
        )?,
    ];
    statements.extend(enqueue_statements(
        &db,
        &auth.uid,
        std::slice::from_ref(&claim_id),
        now,
    )?);
    db.batch(statements).await?;
    drain_pending_embeddings(&ctx.env, DRAIN_BATCH_SIZE).await?;
    Ok(
        Response::from_json(&json!({ "id": id, "sourceId": source_id, "claimId": claim_id }))?
            .with_status(201),
    )
}

async fn handle_source_revision(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let payload = body
        .as_ref()
        .and_then(|b| b.get("payload"))
        .filter(|p| p.is_object())
        .cloned();
    let observed_at = match body.as_ref().and_then(|b| b.get("observedAt")) {
        None | Some(Value::Null) => Some(now_ms()),
        Some(v) => json_to_i64(v),
    };
    let (Some(payload), Some(observed_at)) = (payload, observed_at.filter(|o| *o > 0)) else {
        return error_json("Invalid source revision", 400);
    };
    let source_id = ctx.param("sourceId").cloned().unwrap_or_default();
    let source = d1_first(
        &db,
        "SELECT s.id, COALESCE(MAX(r.revision), 0) AS revision\n     FROM memory_sources s LEFT JOIN memory_source_revisions r ON r.source_id = s.id AND r.uid = s.uid\n     WHERE s.id = ?1 AND s.uid = ?2 AND s.tombstoned_at IS NULL GROUP BY s.id",
        &[s(&source_id), s(&auth.uid)],
    )
    .await?;
    let Some(source) = source else {
        return error_json("Source not found", 404);
    };
    let serialized = serde_json::to_string(&payload).unwrap_or("{}".into());
    let content_hash = sha256_hex(&serialized);
    let id = uuid_v4();
    let revision = source.get("revision").and_then(json_to_i64).unwrap_or(0) + 1;
    let now = now_ms();
    let inserted = d1_run(
        &db,
        "INSERT OR IGNORE INTO memory_source_revisions\n       (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)\n     SELECT ?1, id, uid, ?2, ?3, ?4, ?5, ?6 FROM memory_sources\n     WHERE id = ?7 AND uid = ?8 AND tombstoned_at IS NULL",
        &[s(&id), n(revision), s(&content_hash), s(&serialized), n(observed_at), n(now), s(&source_id), s(&auth.uid)],
    )
    .await?;
    if changes(&inserted) != 1 {
        return error_json("Source revision conflict", 409);
    }
    Ok(Response::from_json(&json!({ "id": id, "sourceId": source_id, "revision": revision, "contentHash": content_hash }))?.with_status(201))
}

async fn handle_source_delete(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let source_id = ctx.param("sourceId").cloned().unwrap_or_default();
    let now = now_ms();
    let source = d1_run(
        &db,
        "UPDATE memory_sources SET tombstoned_at = ?1, updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND tombstoned_at IS NULL",
        &[n(now), s(&source_id), s(&auth.uid)],
    )
    .await?;
    if changes(&source) != 1 {
        return error_json("Source not found", 404);
    }
    db.batch(vec![
        stmt(
            &db,
            "UPDATE memory_claims SET retracted_at = ?1, recorded_until = ?1, status = 'superseded'\n       WHERE uid = ?2 AND retracted_at IS NULL\n         AND EXISTS (\n           SELECT 1 FROM memory_claim_evidence ce\n           JOIN memory_evidence e ON e.id = ce.evidence_id\n           JOIN memory_source_revisions r ON r.id = e.source_revision_id\n           WHERE ce.claim_id = memory_claims.id AND ce.uid = ?2\n         )\n         AND NOT EXISTS (\n           SELECT 1 FROM memory_claim_evidence ce\n           JOIN memory_evidence e ON e.id = ce.evidence_id\n           JOIN memory_source_revisions r ON r.id = e.source_revision_id\n           JOIN memory_sources s ON s.id = r.source_id\n           WHERE ce.claim_id = memory_claims.id AND ce.uid = ?2 AND s.tombstoned_at IS NULL\n         )",
            &[n(now), s(&auth.uid)],
        )?,
        stmt(
            &db,
            "UPDATE memory_daily_reviews SET retracted_at = ?1\n       WHERE uid = ?2 AND retracted_at IS NULL AND EXISTS (\n         SELECT 1 FROM memory_daily_review_citations rc\n         JOIN memory_evidence e ON e.id = rc.evidence_id\n         JOIN memory_source_revisions r ON r.id = e.source_revision_id\n         WHERE rc.review_id = memory_daily_reviews.id AND rc.uid = ?2 AND r.source_id = ?3\n       )",
            &[n(now), s(&auth.uid), s(&source_id)],
        )?,
    ])
    .await?;
    let retracted = d1_all(
        &db,
        "SELECT id FROM memory_claims WHERE uid = ?1 AND retracted_at = ?2",
        &[s(&auth.uid), n(now)],
    )
    .await?;
    let retracted_ids: Vec<String> = retracted.iter().map(|r| str_field(r, "id")).collect();
    if !retracted_ids.is_empty() {
        let statements = enqueue_statements(&db, &auth.uid, &retracted_ids, now)?;
        db.batch(statements).await?;
        drain_pending_embeddings(&ctx.env, DRAIN_BATCH_SIZE).await?;
    }
    Ok(Response::empty()?.with_status(204))
}

async fn handle_daily_reviews_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    Response::from_json(&json!({ "reviews": list_daily_reviews(&db, &auth.uid, 100).await? }))
}

/// Port of `listDailyReviews` (memory-read.ts).
pub(crate) async fn list_daily_reviews(
    db: &D1Database,
    uid: &str,
    limit: usize,
) -> Result<Vec<Value>> {
    let rows = d1_all(
        db,
        "SELECT r.id, r.local_date, r.input_revision, r.body, r.created_at, r.updated_at,\n            e.id AS evidence_id, e.quote, e.locator, e.source_revision_id, sr.source_id\n     FROM memory_daily_reviews r\n     LEFT JOIN memory_daily_review_citations rc ON rc.review_id = r.id AND rc.uid = r.uid\n     LEFT JOIN memory_evidence e ON e.id = rc.evidence_id AND e.uid = rc.uid\n     LEFT JOIN memory_source_revisions sr ON sr.id = e.source_revision_id AND sr.uid = e.uid\n     WHERE r.uid = ?1 AND r.retracted_at IS NULL\n     ORDER BY r.local_date DESC, r.updated_at DESC LIMIT 300",
        &[s(uid)],
    )
    .await?;
    let mut order: Vec<String> = Vec::new();
    let mut reviews: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for row in &rows {
        let id = str_field(row, "id");
        let entry = reviews.entry(id.clone()).or_insert_with(|| {
            order.push(id.clone());
            json!({
                "id": id,
                "localDate": str_field(row, "local_date"),
                "inputRevision": str_field(row, "input_revision"),
                "body": str_field(row, "body"),
                "citations": [],
                "createdAt": row.get("created_at").and_then(json_to_i64).unwrap_or(0),
                "updatedAt": row.get("updated_at").and_then(json_to_i64).unwrap_or(0),
            })
        });
        if !matches!(row.get("evidence_id"), None | Some(Value::Null)) {
            if let Some(arr) = entry.get_mut("citations").and_then(Value::as_array_mut) {
                arr.push(json!({
                    "id": str_field(row, "evidence_id"),
                    "sourceId": str_field(row, "source_id"),
                    "sourceRevisionId": str_field(row, "source_revision_id"),
                    "quote": str_field(row, "quote"),
                    "locator": parse_locator(row.get("locator")),
                }));
            }
        }
    }
    Ok(order
        .into_iter()
        .take(limit)
        .filter_map(|id| reviews.remove(&id))
        .collect())
}

async fn handle_daily_reviews_post(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let body_ref = body.as_ref();
    let local_date = trimmed(body_ref.and_then(|b| b.get("localDate")), 10);
    let input_revision = trimmed(body_ref.and_then(|b| b.get("inputRevision")), 200);
    let review_body = trimmed(body_ref.and_then(|b| b.get("body")), 50_000);
    let citation_ids = body_ref
        .and_then(|b| b.get("citationIds"))
        .and_then(Value::as_array);

    let date_ok = local_date.as_deref().map(is_iso_date).unwrap_or(false);
    let citations_ok = citation_ids
        .map(|arr| !arr.is_empty() && arr.iter().all(|v| trimmed(Some(v), 100).is_some()))
        .unwrap_or(false);
    let (Some(local_date), Some(input_revision), Some(review_body), true, true) = (
        local_date,
        input_revision,
        review_body,
        date_ok,
        citations_ok,
    ) else {
        return error_json("Invalid daily review", 400);
    };
    let citation_ids = citation_ids.unwrap();

    let existing = d1_first(
        &db,
        "SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3",
        &[s(&auth.uid), s(&local_date), s(&input_revision)],
    )
    .await?;
    let id = existing
        .as_ref()
        .map(|r| str_field(r, "id"))
        .unwrap_or_else(uuid_v4);
    let now = now_ms();
    let mut statements = vec![
        stmt(
            &db,
            "INSERT INTO memory_daily_reviews (id, uid, local_date, input_revision, body, created_at, updated_at)\n       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)\n       ON CONFLICT(uid, local_date, input_revision) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at, retracted_at = NULL",
            &[s(&id), s(&auth.uid), s(&local_date), s(&input_revision), s(&review_body), n(now)],
        )?,
        stmt(
            &db,
            "DELETE FROM memory_daily_review_citations\n       WHERE uid = ?1 AND review_id = (\n         SELECT id FROM memory_daily_reviews WHERE uid = ?1 AND local_date = ?2 AND input_revision = ?3\n       )",
            &[s(&auth.uid), s(&local_date), s(&input_revision)],
        )?,
    ];
    for citation in citation_ids {
        let evidence_id = citation.as_str().unwrap_or_default();
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO memory_daily_review_citations (uid, review_id, evidence_id)\n           SELECT ?1, r.id, e.id FROM memory_daily_reviews r, memory_evidence e\n           WHERE r.uid = ?1 AND r.local_date = ?2 AND r.input_revision = ?3 AND e.id = ?4 AND e.uid = ?1",
            &[s(&auth.uid), s(&local_date), s(&input_revision), s(evidence_id)],
        )?);
    }
    db.batch(statements).await?;
    Ok(Response::from_json(&json!({ "id": id }))?.with_status(201))
}

fn is_iso_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes.iter().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                *b == b'-'
            } else {
                b.is_ascii_digit()
            }
        })
}

// ---------------------------------------------------------------------------
// currents.ts
// ---------------------------------------------------------------------------

const SELECT_CURRENT_SQL: &str = "SELECT c.*, s.id AS source_id, s.kind AS source_kind, json_extract(c.proposed_action, '$.instruction') AS instruction\n     FROM currents c\n     JOIN memory_evidence e ON e.id = c.evidence_id AND e.uid = c.uid\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     WHERE c.id = ?1 AND c.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL";

pub(crate) async fn select_current(db: &D1Database, uid: &str, id: &str) -> Result<Option<Value>> {
    d1_first(db, SELECT_CURRENT_SQL, &[s(id), s(uid)]).await
}

async fn handle_current_generate(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let uid = auth.uid;

    let settings = d1_first(
        &db,
        "SELECT value FROM user_settings WHERE uid = ?1",
        &[s(&uid)],
    )
    .await?;
    if let Some(settings) = &settings {
        let value = settings.get("value").and_then(Value::as_str).unwrap_or("");
        match serde_json::from_str::<Value>(value) {
            Ok(parsed) => {
                if parsed.get("proactiveRecommendations") == Some(&Value::Bool(false)) {
                    return Response::from_json(&json!({ "current": Value::Null }));
                }
            }
            Err(_) => return error_json("Invalid settings", 500),
        }
    }

    let now = now_ms();
    let source = d1_first(
        &db,
        "SELECT c.id AS claim_id, c.content, c.value, ce.evidence_id,\n            ce.confidence_basis_points, e.quote\n     FROM memory_profile_entries p\n     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid\n     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid\n       AND ce.relation = 'supports'\n     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     LEFT JOIN currents existing ON existing.uid = p.uid\n       AND existing.generation_key = 'claim:' || c.id\n     WHERE p.uid = ?1 AND p.profile_kind = 'current' AND p.status != 'archived'\n       AND c.status = 'accepted' AND c.retracted_at IS NULL\n       AND (c.valid_from IS NULL OR c.valid_from <= ?2)\n       AND (c.valid_to IS NULL OR c.valid_to > ?2)\n       AND (c.recorded_until IS NULL OR c.recorded_until > ?2)\n       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')\n       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')\n       AND ce.relation = 'supports' AND e.tombstoned_at IS NULL\n       AND s.tombstoned_at IS NULL AND existing.id IS NULL\n     ORDER BY p.updated_at DESC, ce.confidence_basis_points DESC, c.id, e.id\n     LIMIT 1",
        &[s(&uid), n(now)],
    )
    .await?;
    let Some(source) = source else {
        return Response::from_json(&json!({ "current": Value::Null }));
    };
    let claim_id = str_field(&source, "claim_id");
    let value = match source.get("value") {
        Some(Value::Null) | None => str_field(&source, "content"),
        Some(v) => v.as_str().map(str::to_string).unwrap_or_default(),
    };
    let value = value.trim().to_string();
    let content = str_field(&source, "content").trim().to_string();
    let quote = str_field(&source, "quote").trim().to_string();
    if value.is_empty() || content.is_empty() || quote.is_empty() {
        return error_json("Current source is invalid", 500);
    }
    let id = uuid_v4();
    let confidence_bps = source
        .get("confidence_basis_points")
        .and_then(json_to_i64)
        .unwrap_or(0);
    let proposed_action = json!({
        "kind": "review",
        "instruction": bounded(&format!("Review this memory and decide the smallest next action: {value}"), 500),
    })
    .to_string();
    let inserted = d1_run(
        &db,
        "INSERT OR IGNORE INTO currents\n      (id, uid, evidence_id, title, summary, reason, confidence_basis_points,\n       proposed_action, status, surface_at, generation_key, created_at, updated_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?9, ?9)",
        &[
            s(&id),
            s(&uid),
            nullable_s(source.get("evidence_id").and_then(Value::as_str)),
            s(&bounded(&format!("Revisit: {value}"), 120)),
            s(&bounded(&content, 500)),
            s(&bounded(&format!("Based on: {quote}"), 500)),
            n(confidence_bps),
            s(&proposed_action),
            n(now),
            s(&format!("claim:{claim_id}")),
        ],
    )
    .await?;
    if changes(&inserted) == 1 {
        let current = select_current(&db, &uid, &id).await?.unwrap_or(Value::Null);
        return Ok(
            Response::from_json(&json!({ "current": row_to_current(&current) }))?.with_status(201),
        );
    }
    let existing = d1_first(
        &db,
        "SELECT id FROM currents WHERE uid = ?1 AND generation_key = ?2",
        &[s(&uid), s(&format!("claim:{claim_id}"))],
    )
    .await?;
    let current = match existing {
        Some(row) => {
            let existing_id = str_field(&row, "id");
            select_current(&db, &uid, &existing_id)
                .await?
                .map(|r| row_to_current(&r))
                .unwrap_or(Value::Null)
        }
        None => Value::Null,
    };
    Response::from_json(&json!({ "current": current }))
}

async fn handle_current_candidates(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let input = match validate_candidate(body.as_ref()) {
        Ok(input) => input,
        Err(message) => return error_json(message, 400),
    };
    let evidence = d1_first(
        &db,
        "SELECT e.id FROM memory_evidence e\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     WHERE e.id = ?1 AND e.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL",
        &[s(&input.evidence_id), s(&auth.uid)],
    )
    .await?;
    if evidence.is_none() {
        return error_json("Cited evidence not found", 404);
    }
    let id = uuid_v4();
    let now = now_ms();
    let proposed_action = json!({ "kind": "review", "instruction": input.instruction }).to_string();
    d1_run(
        &db,
        "INSERT INTO currents\n      (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action,\n       status, surface_at, expires_at, created_at, updated_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?11, ?11)",
        &[
            s(&id),
            s(&auth.uid),
            s(&input.evidence_id),
            s(&input.title),
            s(&input.summary),
            s(&input.reason),
            n(input.confidence_basis_points),
            s(&proposed_action),
            n(input.surface_at),
            nullable_n(input.expires_at),
            n(now),
        ],
    )
    .await?;
    let current = select_current(&db, &auth.uid, &id)
        .await?
        .unwrap_or(Value::Null);
    Ok(Response::from_json(&json!({ "current": row_to_current(&current) }))?.with_status(201))
}

async fn handle_meeting_actions(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    let body = json_object(&mut req).await;
    let input = match validate_meeting_actions(body.as_ref()) {
        Ok(input) => input,
        Err(message) => return error_json(message, 400),
    };
    let now = now_ms();
    let mut statements = Vec::with_capacity(input.actions.len() * 5);
    for (index, action) in input.actions.iter().enumerate() {
        let key = format!("meeting:{}:{index}", input.ended_at_ms);
        let source_id = format!("{key}:source");
        let revision_id = format!("{key}:revision");
        let evidence_id = format!("{key}:evidence");
        let current_id = format!("{key}:current");
        let delivery_id = format!("{key}:delivery");
        let payload = json!({
            "title": input.title,
            "summary": input.summary,
            "action": action,
            "endedAtMs": input.ended_at_ms,
        })
        .to_string();
        let proposed_action = json!({ "kind": "review", "instruction": action }).to_string();
        let delivery_text = format!("Action from {}: {}", input.title, action);
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO memory_sources (id, uid, kind, created_at, updated_at) VALUES (?1, ?2, 'meeting', ?3, ?3)",
            &[s(&source_id), s(&auth.uid), n(now)],
        )?);
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO memory_source_revisions (id, source_id, uid, revision, content_hash, payload, observed_at, created_at) VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?6)",
            &[s(&revision_id), s(&source_id), s(&auth.uid), s(&sha256_hex(&payload)), s(&payload), n(input.ended_at_ms)],
        )?);
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO memory_evidence (id, uid, source_revision_id, quote, locator, created_at) VALUES (?1, ?2, ?3, ?4, '[]', ?5)",
            &[s(&evidence_id), s(&auth.uid), s(&revision_id), s(action), n(now)],
        )?);
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO currents (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action, status, surface_at, generation_key, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'Action item captured from a completed meeting', 10000, ?6, 'surfaced', ?7, ?8, ?7, ?7)",
            &[s(&current_id), s(&auth.uid), s(&evidence_id), s(action), s(&input.summary), s(&proposed_action), n(now), s(&key)],
        )?);
        statements.push(stmt(
            &db,
            "INSERT OR IGNORE INTO channel_deliveries (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at) SELECT ?1, b.uid, b.channel, ?2, COALESCE(b.channel_chat_id, b.channel_user_id), ?3, ?4, ?4, ?4 FROM channel_bindings b WHERE b.uid = ?5 AND b.revoked_at IS NULL ORDER BY b.verified_at DESC LIMIT 1",
            &[s(&delivery_id), s(&key), s(&delivery_text), n(now), s(&auth.uid)],
        )?);
    }
    db.batch(statements).await?;
    Response::from_json(&json!({ "created": input.actions.len() }))
}

async fn handle_currents_list(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    Response::from_json(&json!({ "currents": list_currents(&db, &auth.uid).await? }))
}

async fn handle_current_refresh(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let force = body
        .as_ref()
        .and_then(|b| b.get("force"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let outcome = refresh_currents(&ctx.env, &db, &auth.uid, force, now_ms()).await?;
    Response::from_json(&outcome)
}

// ---------------------------------------------------------------------------
// currents-refresh.ts pipeline
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GenerateOutcomeKind {
    Created,
    Existing,
    Empty,
    Disabled,
    InvalidSettings,
    InvalidSource,
}

async fn read_refresh_state(db: &D1Database, uid: &str) -> Result<RefreshState> {
    let row = d1_first(
        db,
        "SELECT last_checked_at, last_regenerated_at, memory_watermark FROM currents_refresh_state WHERE uid = ?1",
        &[s(uid)],
    )
    .await?;
    Ok(match row {
        Some(row) => RefreshState {
            last_checked_at: row
                .get("last_checked_at")
                .and_then(json_to_i64)
                .unwrap_or(0),
            last_regenerated_at: row
                .get("last_regenerated_at")
                .and_then(json_to_i64)
                .unwrap_or(0),
            memory_watermark: row
                .get("memory_watermark")
                .and_then(json_to_i64)
                .unwrap_or(0),
        },
        None => RefreshState {
            last_checked_at: 0,
            last_regenerated_at: 0,
            memory_watermark: 0,
        },
    })
}

async fn write_refresh_state(
    db: &D1Database,
    uid: &str,
    last_checked_at: i64,
    last_regenerated_at: i64,
    memory_watermark: i64,
) -> Result<()> {
    d1_run(
        db,
        "INSERT INTO currents_refresh_state
      (uid, last_checked_at, last_regenerated_at, memory_watermark)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(uid) DO UPDATE SET
       last_checked_at = excluded.last_checked_at,
       last_regenerated_at = excluded.last_regenerated_at,
       memory_watermark = excluded.memory_watermark",
        &[
            s(uid),
            n(last_checked_at),
            n(last_regenerated_at),
            n(memory_watermark),
        ],
    )
    .await?;
    Ok(())
}

async fn gather_refresh_context(db: &D1Database, uid: &str) -> Result<RefreshContext> {
    let surfaced = d1_all(
        db,
        "SELECT title, updated_at FROM currents
     WHERE uid = ?1 AND status IN ('surfaced', 'accepted')
     ORDER BY updated_at DESC LIMIT 20",
        &[s(uid)],
    )
    .await?;
    let memory = d1_all(
        db,
        "SELECT e.id AS evidence_id, s.kind AS source_kind, e.quote, c.content, c.recorded_at
     FROM memory_claims c
     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid
       AND ce.relation = 'supports'
     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL
       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
       AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL
     ORDER BY c.recorded_at DESC, c.id ASC
     LIMIT 24",
        &[s(uid)],
    )
    .await?;
    let memory_lines: Vec<MemoryLine> = memory
        .iter()
        .map(|row| MemoryLine {
            evidence_id: str_field(row, "evidence_id"),
            source_kind: opt_str_field(row, "source_kind"),
            quote: str_field(row, "quote"),
            content: str_field(row, "content"),
            recorded_at: row.get("recorded_at").and_then(json_to_i64).unwrap_or(0),
        })
        .collect();
    let memory_watermark = memory_lines
        .iter()
        .map(|line| line.recorded_at)
        .max()
        .unwrap_or(0);
    let existing_titles: Vec<String> = surfaced.iter().map(|row| str_field(row, "title")).collect();
    let newest_updated_at = if surfaced.is_empty() {
        None
    } else {
        surfaced
            .iter()
            .filter_map(|row| row.get("updated_at").and_then(json_to_i64))
            .max()
    };
    Ok(RefreshContext {
        surfaced_count: surfaced.len(),
        newest_updated_at,
        memory_watermark,
        existing_titles,
        memory_lines,
    })
}

async fn speed_completion(env: &Env, prompt: &str) -> Option<String> {
    let secret = env_get(env, "OPENROUTER_API_KEY")?.trim().to_string();
    if secret.is_empty() {
        return None;
    }
    let model = managed_ai::model_for_tier(managed_ai::ModelTier::Speed, |name| env_get(env, name));
    let endpoint = env_get(env, "OPENROUTER_CHAT_COMPLETIONS_URL")
        .unwrap_or_else(|| managed_ai::OPENROUTER_COMPLETION_ENDPOINT.to_owned());
    let endpoint_url = managed_ai::validate_pinned_endpoint(
        &endpoint,
        managed_ai::OPENROUTER_COMPLETION_ENDPOINT,
        managed_ai::OPENROUTER_HOSTNAME,
    )?;
    let body = json!({
        "model": model,
        "messages": [{ "role": "user", "content": prompt }],
        "stream": false,
        "max_tokens": 256,
        "temperature": 0,
    });
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    let _ = headers.set("authorization", &format!("Bearer {secret}"));
    let _ = headers.set("content-type", "application/json");
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let request = Request::new_with_init(endpoint_url.as_str(), &init).ok()?;
    let mut upstream = worker::Fetch::Request(request).send().await.ok()?;
    if upstream.status_code() >= 300 {
        return None;
    }
    let value = upstream.json::<Value>().await.ok()?;
    let content = value
        .get("choices")?
        .get(0)?
        .get("message")?
        .get("content")?
        .as_str()?;
    let trimmed = content.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

async fn ai_needs_refresh(
    env: &Env,
    context: &RefreshContext,
    state: &RefreshState,
) -> Option<bool> {
    if context.memory_lines.is_empty() {
        return None;
    }
    let mut prompt = vec![
        "Decide whether proactive task suggestions should refresh.".to_string(),
        "Reply ONLY with JSON: {\"refresh\":true|false,\"reason\":\"...\"}".to_string(),
        String::new(),
        format!("Existing currents ({}):", context.existing_titles.len()),
    ];
    prompt.extend(
        context
            .existing_titles
            .iter()
            .take(8)
            .map(|title| format!("- {title}")),
    );
    prompt.push(String::new());
    prompt.push(format!(
        "Last regenerated ms: {}",
        state.last_regenerated_at
    ));
    prompt.push(format!(
        "Memory watermark ms: {}; latest memory ms: {}",
        state.memory_watermark, context.memory_watermark
    ));
    prompt.push(String::new());
    prompt.push("Recent memory excerpts:".to_string());
    prompt.extend(context.memory_lines.iter().take(6).map(|line| {
        let source = line.source_kind.as_deref().unwrap_or("memory");
        format!(
            "- [{source}] {}",
            currents_refresh::collapse(&line.content)
                .chars()
                .take(160)
                .collect::<String>()
        )
    }));
    let content = speed_completion(env, &prompt.join("\n")).await?;
    let parsed = currents_refresh::parse_json_object(&content)?;
    match parsed.get("refresh") {
        Some(Value::Bool(true)) => Some(true),
        Some(Value::Bool(false)) => Some(false),
        _ => None,
    }
}

async fn ai_drafts(env: &Env, context: &RefreshContext) -> Vec<GeneratedDraft> {
    if context.memory_lines.is_empty() {
        return Vec::new();
    }
    let allowed: std::collections::HashSet<String> = context
        .memory_lines
        .iter()
        .map(|line| line.evidence_id.clone())
        .collect();
    let mut prompt = vec![
        "Generate refreshed proactive suggestions ('currents') for the user.".to_string(),
        "Return ONLY JSON:".to_string(),
        "{\"items\":[{\"contentKind\":\"agent_action|human_action|awareness\",\"title\":\"...\",\"summary\":\"...\",\"reason\":\"...\",\"instruction\":\"...\",\"evidenceId\":\"...\",\"tool\":\"optional for agent_action\"}]}"
            .to_string(),
        String::new(),
        "Mix all three kinds:".to_string(),
        "- agent_action: Omi/automation can execute (include tool when obvious)".to_string(),
        "- human_action: the user should do".to_string(),
        "- awareness: meetings, events, deadlines to know about".to_string(),
        String::new(),
        "Use evidenceId values from this list only:".to_string(),
    ];
    prompt.extend(context.memory_lines.iter().take(12).map(|line| {
        let source = line.source_kind.as_deref().unwrap_or("memory");
        format!(
            "- {} [{source}] {}",
            line.evidence_id,
            currents_refresh::collapse(&line.content)
                .chars()
                .take(140)
                .collect::<String>()
        )
    }));
    prompt.push(String::new());
    prompt.push("Avoid repeating these existing titles:".to_string());
    prompt.extend(
        context
            .existing_titles
            .iter()
            .take(8)
            .map(|title| format!("- {title}")),
    );
    let content = match speed_completion(env, &prompt.join("\n")).await {
        Some(content) => content,
        None => return Vec::new(),
    };
    currents_refresh::parse_drafts(&content, &allowed)
}

async fn proactive_enabled(db: &D1Database, uid: &str) -> Result<&'static str> {
    let settings = d1_first(
        db,
        "SELECT value FROM user_settings WHERE uid = ?1",
        &[s(uid)],
    )
    .await?;
    let Some(settings) = settings else {
        return Ok("yes");
    };
    let value = settings.get("value").and_then(Value::as_str).unwrap_or("");
    match serde_json::from_str::<Value>(value) {
        Ok(parsed) => {
            if parsed.get("proactiveRecommendations") == Some(&Value::Bool(false)) {
                Ok("no")
            } else {
                Ok("yes")
            }
        }
        Err(_) => Ok("invalid"),
    }
}

pub(crate) async fn generate_one_current(
    db: &D1Database,
    uid: &str,
    now: i64,
) -> Result<GenerateOutcomeKind> {
    match proactive_enabled(db, uid).await? {
        "no" => return Ok(GenerateOutcomeKind::Disabled),
        "invalid" => return Ok(GenerateOutcomeKind::InvalidSettings),
        _ => {}
    }
    let source = d1_first(
        db,
        "SELECT c.id AS claim_id, c.content, c.value, ce.evidence_id,\n            ce.confidence_basis_points, e.quote\n     FROM memory_profile_entries p\n     JOIN memory_claims c ON c.id = p.claim_id AND c.uid = p.uid\n     JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid\n       AND ce.relation = 'supports'\n     JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     LEFT JOIN currents existing ON existing.uid = p.uid\n       AND existing.generation_key = 'claim:' || c.id\n     WHERE p.uid = ?1 AND p.profile_kind = 'current' AND p.status != 'archived'\n       AND c.status = 'accepted' AND c.retracted_at IS NULL\n       AND (c.valid_from IS NULL OR c.valid_from <= ?2)\n       AND (c.valid_to IS NULL OR c.valid_to > ?2)\n       AND (c.recorded_until IS NULL OR c.recorded_until > ?2)\n       AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')\n       AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')\n       AND ce.relation = 'supports' AND e.tombstoned_at IS NULL\n       AND s.tombstoned_at IS NULL AND existing.id IS NULL\n     ORDER BY p.updated_at DESC, ce.confidence_basis_points DESC, c.id, e.id\n     LIMIT 1",
        &[s(uid), n(now)],
    )
    .await?;
    let Some(source) = source else {
        return Ok(GenerateOutcomeKind::Empty);
    };
    let claim_id = str_field(&source, "claim_id");
    let value = match source.get("value") {
        Some(Value::Null) | None => str_field(&source, "content"),
        Some(v) => v.as_str().map(str::to_string).unwrap_or_default(),
    };
    let value = value.trim().to_string();
    let content = str_field(&source, "content").trim().to_string();
    let quote = str_field(&source, "quote").trim().to_string();
    if value.is_empty() || content.is_empty() || quote.is_empty() {
        return Ok(GenerateOutcomeKind::InvalidSource);
    }
    let id = uuid_v4();
    let confidence_bps = source
        .get("confidence_basis_points")
        .and_then(json_to_i64)
        .unwrap_or(0);
    let proposed_action = json!({
        "kind": "human_action",
        "instruction": bounded(&format!("Review this memory and decide the smallest next action: {value}"), 500),
    })
    .to_string();
    let title = bounded(&format!("Revisit: {value}"), 120);
    let summary = bounded(&content, 500);
    let crepus = hero_crepus(&title, &summary, "Do this next");
    let inserted = d1_run(
        db,
        "INSERT OR IGNORE INTO currents\n      (id, uid, evidence_id, title, summary, reason, confidence_basis_points,\n       proposed_action, status, surface_at, generation_key, created_at, updated_at, crepus)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?9, ?9, ?11)",
        &[
            s(&id),
            s(uid),
            nullable_s(source.get("evidence_id").and_then(Value::as_str)),
            s(&title),
            s(&summary),
            s(&bounded(&format!("Based on: {quote}"), 500)),
            n(confidence_bps),
            s(&proposed_action),
            n(now),
            s(&format!("claim:{claim_id}")),
            nullable_s(crepus.as_deref()),
        ],
    )
    .await?;
    if changes(&inserted) == 1 {
        return Ok(GenerateOutcomeKind::Created);
    }
    let existing = d1_first(
        db,
        "SELECT 1 AS ok FROM currents WHERE uid = ?1 AND generation_key = ?2",
        &[s(uid), s(&format!("claim:{claim_id}"))],
    )
    .await?;
    if existing.is_some() {
        Ok(GenerateOutcomeKind::Existing)
    } else {
        Ok(GenerateOutcomeKind::Empty)
    }
}

async fn expire_refresh_batch(db: &D1Database, uid: &str, now: i64) -> Result<()> {
    d1_run(
        db,
        "UPDATE currents SET status = 'expired', updated_at = ?1
     WHERE uid = ?2 AND status IN ('candidate', 'surfaced', 'snoozed')
       AND generation_key LIKE 'refresh:%'",
        &[n(now), s(uid)],
    )
    .await?;
    Ok(())
}

async fn insert_refresh_draft(
    db: &D1Database,
    uid: &str,
    draft: &GeneratedDraft,
    generation_key: &str,
    now: i64,
) -> Result<()> {
    let evidence = d1_first(
        db,
        "SELECT e.id FROM memory_evidence e
     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
     WHERE e.id = ?1 AND e.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL",
        &[s(&draft.evidence_id), s(uid)],
    )
    .await?;
    if evidence.is_none() {
        return Ok(());
    }
    let mut proposed = json!({
        "kind": draft.content_kind.as_str(),
        "instruction": draft.instruction,
    });
    if let Some(tool) = &draft.tool {
        if let Some(map) = proposed.as_object_mut() {
            map.insert("tool".into(), json!(tool));
        }
    }
    let id = uuid_v4();
    d1_run(
        db,
        "INSERT INTO currents
      (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action,
       status, surface_at, expires_at, created_at, updated_at, crepus, generation_key)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, NULL, ?10, ?10, NULL, ?11)",
        &[
            s(&id),
            s(uid),
            s(&draft.evidence_id),
            s(&draft.title),
            s(&draft.summary),
            s(&draft.reason),
            n(7_200),
            s(&proposed.to_string()),
            n(now),
            n(now),
            s(generation_key),
        ],
    )
    .await?;
    Ok(())
}

async fn regenerate_currents(
    env: &Env,
    db: &D1Database,
    uid: &str,
    context: &RefreshContext,
    now: i64,
) -> Result<i64> {
    expire_refresh_batch(db, uid, now).await?;
    let mut created = 0i64;
    for _ in 0..3 {
        match generate_one_current(db, uid, now).await? {
            GenerateOutcomeKind::Created => created += 1,
            _ => break,
        }
    }
    let ai = ai_drafts(env, context).await;
    let drafts = if ai.is_empty() {
        currents_refresh::heuristic_drafts(context)
    } else {
        ai
    };
    let local_date = channel_commands::iso_date(now);
    for (index, draft) in drafts.iter().enumerate() {
        if created >= REFRESH_BATCH_SIZE as i64 {
            break;
        }
        let generation_key = format!("refresh:{local_date}:{index}");
        let existing = d1_first(
            db,
            "SELECT 1 AS ok FROM currents WHERE uid = ?1 AND generation_key = ?2",
            &[s(uid), s(&generation_key)],
        )
        .await?;
        if existing.is_some() {
            continue;
        }
        if insert_refresh_draft(db, uid, draft, &generation_key, now)
            .await
            .is_ok()
        {
            created += 1;
        }
    }
    Ok(created)
}

async fn refresh_currents(
    env: &Env,
    db: &D1Database,
    uid: &str,
    force: bool,
    now: i64,
) -> Result<Value> {
    let state = read_refresh_state(db, uid).await?;
    let context = gather_refresh_context(db, uid).await?;
    if currents_refresh::within_check_ttl(&state, now, force) {
        return Ok(json!({
            "refreshed": false,
            "reason": "check_ttl",
            "checkedAt": state.last_checked_at,
            "regeneratedAt": if state.last_regenerated_at > 0 { Value::from(state.last_regenerated_at) } else { Value::Null },
            "currents": list_currents(db, uid).await?,
        }));
    }
    let heuristic = currents_refresh::heuristic_needs_refresh(&context, &state, now, force);
    let mut should_refresh = heuristic.refresh;
    let mut reason = heuristic.reason;
    if should_refresh
        && !force
        && heuristic.reason != "no_surfaced_currents"
        && heuristic.reason != "currents_stale"
    {
        match ai_needs_refresh(env, &context, &state).await {
            Some(false) => {
                should_refresh = false;
                reason = "ai_fresh";
            }
            Some(true) => reason = "ai_stale",
            None => {}
        }
    }
    if should_refresh
        && !force
        && state.last_regenerated_at > 0
        && now - state.last_regenerated_at < currents_refresh::MIN_REGENERATE_INTERVAL_MS
        && heuristic.reason != "no_surfaced_currents"
        && heuristic.reason != "currents_stale"
        && heuristic.reason != "new_memory"
    {
        should_refresh = false;
        reason = "regenerate_ttl";
    }
    let mut regenerated_at = if state.last_regenerated_at > 0 {
        Some(state.last_regenerated_at)
    } else {
        None
    };
    if should_refresh {
        regenerate_currents(env, db, uid, &context, now).await?;
        regenerated_at = Some(now);
        write_refresh_state(db, uid, now, now, context.memory_watermark).await?;
    } else {
        write_refresh_state(
            db,
            uid,
            now,
            state.last_regenerated_at,
            state.memory_watermark.max(context.memory_watermark),
        )
        .await?;
    }
    Ok(json!({
        "refreshed": should_refresh,
        "reason": reason,
        "checkedAt": now,
        "regeneratedAt": regenerated_at.map(Value::from).unwrap_or(Value::Null),
        "currents": list_currents(db, uid).await?,
    }))
}

/// Port of `listCurrents` (currents.ts): rolls expiry/snooze/surface forward,
/// then returns the ranked open Currents.
pub(crate) async fn list_currents(db: &D1Database, uid: &str) -> Result<Vec<Value>> {
    let now = now_ms();
    d1_run(
        db,
        "UPDATE currents SET status = 'expired', updated_at = ?1\n     WHERE uid = ?2 AND status IN ('candidate', 'surfaced', 'snoozed') AND expires_at IS NOT NULL AND expires_at <= ?1",
        &[n(now), s(uid)],
    )
    .await?;
    d1_run(
        db,
        "UPDATE currents SET status = 'surfaced', snoozed_until = NULL, updated_at = ?1\n     WHERE uid = ?2 AND status = 'snoozed' AND snoozed_until <= ?1",
        &[n(now), s(uid)],
    )
    .await?;
    d1_run(
        db,
        "UPDATE currents SET status = 'surfaced', updated_at = ?1\n     WHERE uid = ?2 AND status = 'candidate' AND surface_at <= ?1",
        &[n(now), s(uid)],
    )
    .await?;
    let rows = d1_all(
        db,
        "SELECT c.*, s.id AS source_id, s.kind AS source_kind, json_extract(c.proposed_action, '$.instruction') AS instruction,\n       COALESCE((SELECT SUM(CASE f.kind WHEN 'dismissed' THEN -1000 ELSE -250 END)\n                 FROM current_feedback f\n                 JOIN currents prior ON prior.id = f.current_id AND prior.uid = f.uid\n                 JOIN memory_evidence pe ON pe.id = prior.evidence_id AND pe.uid = prior.uid\n                 JOIN memory_source_revisions pr ON pr.id = pe.source_revision_id AND pr.uid = pe.uid\n                 JOIN memory_sources ps ON ps.id = pr.source_id AND ps.uid = pr.uid\n                 WHERE f.uid = c.uid AND ps.kind = s.kind), 0)\n       + COALESCE((SELECT SUM(CASE x.state WHEN 'succeeded' THEN 500 WHEN 'failed' THEN -500 ELSE -250 END)\n                   FROM current_executions x\n                   JOIN currents prior ON prior.id = x.current_id AND prior.uid = x.uid\n                   JOIN memory_evidence pe ON pe.id = prior.evidence_id AND pe.uid = prior.uid\n                   JOIN memory_source_revisions pr ON pr.id = pe.source_revision_id AND pr.uid = pe.uid\n                   JOIN memory_sources ps ON ps.id = pr.source_id AND ps.uid = pr.uid\n                   WHERE x.uid = c.uid AND ps.kind = s.kind\n                     AND x.state IN ('succeeded', 'failed', 'outcome_unknown')), 0) AS learned_adjustment\n     FROM currents c\n     JOIN memory_evidence e ON e.id = c.evidence_id AND e.uid = c.uid\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     WHERE c.uid = ?1 AND s.tombstoned_at IS NULL\n       AND e.tombstoned_at IS NULL\n       AND c.status IN ('surfaced', 'accepted')\n     ORDER BY c.confidence_basis_points + learned_adjustment DESC, c.updated_at DESC, c.id ASC LIMIT 100",
        &[s(uid)],
    )
    .await?;
    Ok(rows.iter().map(row_to_current).collect())
}

async fn handle_current_feedback(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let id = ctx.param("id").cloned().unwrap_or_default();
    let body = json_object(&mut req).await;
    let now = now_ms();
    let feedback = match validate_feedback(body.as_ref(), now) {
        Ok(feedback) => feedback,
        Err(message) => return error_json(message, 400),
    };
    let current = select_current(&db, &auth.uid, &id).await?;
    let Some(current) = current else {
        return error_json("Current not found", 404);
    };
    if str_field(&current, "status") != "surfaced" {
        return error_json("Current cannot receive feedback", 409);
    }
    let feedback_id = uuid_v4();
    let results = db
        .batch(vec![
            stmt(
                &db,
                "INSERT OR IGNORE INTO current_feedback (id, uid, current_id, kind, created_at)\n       SELECT ?1, ?2, ?3, ?4, ?5 FROM currents\n       WHERE id = ?3 AND uid = ?2 AND status = 'surfaced'\n         AND (expires_at IS NULL OR expires_at > ?5)",
                &[s(&feedback_id), s(&auth.uid), s(&id), s(&feedback.kind), n(now)],
            )?,
            stmt(
                &db,
                "UPDATE currents SET status = ?1, snoozed_until = ?2, feedback_reference = ?3, updated_at = ?4\n       WHERE id = ?5 AND uid = ?6 AND status = 'surfaced'\n         AND EXISTS (SELECT 1 FROM current_feedback WHERE id = ?3 AND uid = ?6 AND current_id = ?5)",
                &[s(&feedback.kind), nullable_n(feedback.snoozed_until), s(&feedback_id), n(now), s(&id), s(&auth.uid)],
            )?,
        ])
        .await?;
    if changes(&results[0]) != 1 {
        return error_json("Current cannot receive feedback", 409);
    }
    let updated = select_current(&db, &auth.uid, &id)
        .await?
        .unwrap_or(Value::Null);
    Response::from_json(&json!({ "current": row_to_current(&updated) }))
}

async fn handle_current_accept(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let id = ctx.param("id").cloned().unwrap_or_default();
    let current = select_current(&db, &auth.uid, &id).await?;
    let Some(current) = current else {
        return error_json("Current not found", 404);
    };
    if str_field(&current, "status") != "surfaced" {
        return error_json("Current cannot be accepted", 409);
    }
    let execution_id = uuid_v4();
    let approval_nonce = uuid_v4();
    let hash = sha256_hex(&approval_nonce);
    let now = now_ms();
    let proposed_action = str_field(&current, "proposed_action");
    let results = db
        .batch(vec![
            stmt(
                &db,
                "INSERT OR IGNORE INTO current_executions\n       (id, uid, current_id, state, action, approval_nonce_hash, policy_generation, created_at, updated_at)\n       SELECT ?1, ?2, ?3, 'awaiting_approval', ?4, ?5,\n              COALESCE((SELECT revision FROM user_settings WHERE uid = ?2), 0), ?6, ?6 FROM currents\n       WHERE id = ?3 AND uid = ?2 AND status = 'surfaced'\n         AND (expires_at IS NULL OR expires_at > ?6)",
                &[s(&execution_id), s(&auth.uid), s(&id), s(&proposed_action), s(&hash), n(now)],
            )?,
            stmt(
                &db,
                "UPDATE currents SET status = 'accepted', execution_reference = ?1, updated_at = ?2\n       WHERE id = ?3 AND uid = ?4 AND status = 'surfaced'\n         AND EXISTS (SELECT 1 FROM current_executions WHERE id = ?1 AND uid = ?4 AND current_id = ?3)",
                &[s(&execution_id), n(now), s(&id), s(&auth.uid)],
            )?,
        ])
        .await?;
    if changes(&results[0]) != 1 {
        return error_json("Current cannot be accepted", 409);
    }
    let stored = d1_first(
        &db,
        "SELECT policy_generation FROM current_executions WHERE id = ?1 AND uid = ?2",
        &[s(&execution_id), s(&auth.uid)],
    )
    .await?;
    let Some(stored) = stored else {
        return error_json("Current cannot be accepted", 409);
    };
    let policy_generation = stored
        .get("policy_generation")
        .and_then(json_to_i64)
        .unwrap_or(0);
    let action: Value = serde_json::from_str(&proposed_action).unwrap_or(Value::Null);
    Ok(Response::from_json(&json!({
        "executionId": execution_id,
        "approvalNonce": approval_nonce,
        "policyGeneration": policy_generation,
        "action": action,
        "state": "awaiting_approval",
    }))?
    .with_status(201))
}

async fn handle_execution_approve(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let input = match validate_approval(body.as_ref()) {
        Ok(input) => input,
        Err(message) => return error_json(message, 400),
    };
    let nonce_hash = sha256_hex(&input.nonce);
    let token = receipt_token();
    let token_hash = sha256_hex(&token);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let receipt_id = uuid_v4();
    let now = now_ms();
    let expires_at = now + RECEIPT_LIFETIME_MS;
    let approved = d1_first(
        &db,
        "UPDATE current_executions\n       SET state = 'approved', approved_at = ?1, updated_at = ?1,\n           operation_id = ?5, proposal_id = ?6, action_hash = ?7, risk = ?8,\n           receipt_id = ?9, receipt_token_hash = ?10, receipt_issued_at = ?1,\n           receipt_expires_at = ?11\n       WHERE id = ?2 AND uid = ?3 AND state = 'awaiting_approval'\n         AND approval_nonce_hash = ?4 AND created_at > ?12\n         AND policy_generation = ?13\n         AND policy_generation = COALESCE((SELECT revision FROM user_settings WHERE uid = ?3), 0)\n         AND NOT EXISTS (\n           SELECT 1 FROM current_executions existing\n           WHERE existing.uid = ?3 AND (existing.operation_id = ?5 OR existing.proposal_id = ?6)\n         )\n       RETURNING policy_generation",
        &[
            n(now),
            s(&id),
            s(&auth.uid),
            s(&nonce_hash),
            s(&input.operation_id),
            s(&input.proposal_id),
            s(&input.action_hash),
            s(input.risk),
            s(&receipt_id),
            s(&token_hash),
            n(expires_at),
            n(now - APPROVAL_LIFETIME_MS),
            n(input.generation),
        ],
    )
    .await
    .unwrap_or(None);
    let Some(approved) = approved else {
        return error_json("Approval is invalid or already consumed", 409);
    };
    let policy_generation = approved
        .get("policy_generation")
        .and_then(json_to_i64)
        .unwrap_or(0);
    Response::from_json(&json!({
        "executionId": id,
        "state": "approved",
        "receipt": {
            "version": RECEIPT_VERSION,
            "receiptId": receipt_id,
            "receiptToken": token,
            "subject": auth.uid,
            "policyGeneration": policy_generation,
            "operationId": input.operation_id,
            "proposalId": input.proposal_id,
            "actionHash": input.action_hash,
            "risk": input.risk,
            "issuedAtMs": now,
            "expiresAtMs": expires_at,
        },
    }))
}

const UNREPORTED_OUTCOME: &str =
    "{\"detail\":\"Execution authority was claimed, but no outcome was reported\"}";

async fn handle_receipt_claim(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    let body = json_object(&mut req).await;
    let claim_uid = if auth.uid == crate::glue::RECEIPT_CLAIM_AUTH_MARKER {
        let authorization = req
            .headers()
            .get("authorization")
            .ok()
            .flatten()
            .unwrap_or_default();
        let bearer = crate::auth::bearer_token(&authorization).unwrap_or_default();
        let Some(object) = body.as_ref().and_then(Value::as_object) else {
            return error_json("Invalid receipt claim", 400);
        };
        let Some(token) = object
            .get("receiptToken")
            .and_then(Value::as_str)
            .filter(|value| routes_memory::is_receipt_token(value))
        else {
            return error_json("Invalid receipt claim", 400);
        };
        if bearer != token {
            return error_json("Authentication failed", 401);
        }
        let Some(subject) = object
            .get("subject")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return error_json("Invalid receipt claim", 400);
        };
        subject.to_string()
    } else {
        auth.uid.clone()
    };
    ensure_projected(&db, &claim_uid).await?;
    let input = match validate_receipt_claim(body.as_ref(), &claim_uid) {
        Ok(input) => input,
        Err(message) => return error_json(message, 400),
    };
    let token_hash = sha256_hex(&input.token);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let receipt_id = ctx.param("receiptId").cloned().unwrap_or_default();
    let now = now_ms();
    let results = db
        .batch(vec![
            stmt(
                &db,
                "UPDATE current_executions\n       SET receipt_claimed_at = ?1, state = 'outcome_unknown', outcome = ?11, updated_at = ?1\n       WHERE id = ?2 AND uid = ?3 AND state = 'approved'\n         AND receipt_id = ?4 AND receipt_token_hash = ?5\n         AND operation_id = ?6 AND proposal_id = ?7 AND action_hash = ?8 AND risk = ?9\n         AND policy_generation = ?10\n         AND policy_generation = COALESCE((SELECT revision FROM user_settings WHERE uid = ?3), 0)\n         AND receipt_claimed_at IS NULL AND receipt_expires_at > ?1",
                &[
                    n(now),
                    s(&id),
                    s(&claim_uid),
                    s(&receipt_id),
                    s(&token_hash),
                    s(&input.operation_id),
                    s(&input.proposal_id),
                    s(&input.action_hash),
                    s(input.risk),
                    n(input.policy_generation),
                    s(UNREPORTED_OUTCOME),
                ],
            )?,
            stmt(
                &db,
                "UPDATE currents SET status = 'expired', updated_at = ?1\n       WHERE uid = ?2 AND status = 'accepted' AND id = (\n         SELECT current_id FROM current_executions\n         WHERE id = ?3 AND uid = ?2 AND state = 'outcome_unknown'\n           AND outcome = ?4 AND receipt_claimed_at = ?1\n       )",
                &[n(now), s(&claim_uid), s(&id), s(UNREPORTED_OUTCOME)],
            )?,
        ])
        .await?;
    if changes(&results[0]) != 1 {
        return error_json("Receipt is invalid, expired, or already claimed", 409);
    }
    let stored = d1_first(
        &db,
        "SELECT receipt_issued_at, receipt_expires_at FROM current_executions WHERE id = ?1 AND uid = ?2 AND receipt_claimed_at = ?3",
        &[s(&id), s(&claim_uid), n(now)],
    )
    .await?;
    let Some(stored) = stored else {
        return error_json("Claimed receipt could not be loaded", 500);
    };
    Response::from_json(&json!({
        "executionId": id,
        "state": "claimed",
        "receipt": {
            "version": RECEIPT_VERSION,
            "receiptId": receipt_id,
            "subject": claim_uid,
            "policyGeneration": input.policy_generation,
            "operationId": input.operation_id,
            "proposalId": input.proposal_id,
            "actionHash": input.action_hash,
            "risk": input.risk,
            "issuedAtMs": stored.get("receipt_issued_at").and_then(json_to_i64).unwrap_or(0),
            "expiresAtMs": stored.get("receipt_expires_at").and_then(json_to_i64).unwrap_or(0),
            "claimedAtMs": now,
        },
    }))
}

async fn handle_execution_reject(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let nonce = trimmed(body.as_ref().and_then(|b| b.get("approvalNonce")), 200);
    let Some(nonce) = nonce else {
        return error_json("Invalid rejection", 400);
    };
    let hash = sha256_hex(&nonce);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let now = now_ms();
    let results = db
        .batch(vec![
            stmt(
                &db,
                "UPDATE current_executions SET state = 'rejected', updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND state = 'awaiting_approval' AND approval_nonce_hash = ?4",
                &[n(now), s(&id), s(&auth.uid), s(&hash)],
            )?,
            stmt(
                &db,
                "UPDATE currents SET status = 'dismissed', updated_at = ?1\n       WHERE uid = ?2 AND status = 'accepted' AND id = (\n         SELECT current_id FROM current_executions\n         WHERE id = ?3 AND uid = ?2 AND state = 'rejected'\n           AND approval_nonce_hash = ?4 AND updated_at = ?1\n       )",
                &[n(now), s(&auth.uid), s(&id), s(&hash)],
            )?,
        ])
        .await?;
    if changes(&results[0]) != 1 {
        return error_json("Rejection is invalid or already consumed", 409);
    }
    Response::from_json(&json!({ "executionId": id, "state": "rejected" }))
}

async fn handle_execution_outcome(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = authed!(req, ctx);
    let db = ctx.env.d1("DB")?;
    ensure_projected(&db, &auth.uid).await?;
    let body = json_object(&mut req).await;
    let (state, detail) = match validate_outcome(body.as_ref()) {
        Ok(parsed) => parsed,
        Err(message) => return error_json(message, 400),
    };
    let id = ctx.param("id").cloned().unwrap_or_default();
    let now = now_ms();
    let serialized_outcome = json!({ "detail": detail }).to_string();
    let current_status = if state == "succeeded" {
        "completed"
    } else {
        "expired"
    };
    let results = db
        .batch(vec![
            stmt(
                &db,
                "UPDATE current_executions\n       SET state = ?1, outcome = ?2, outcome_reported_at = ?3, updated_at = ?3\n       WHERE id = ?4 AND uid = ?5 AND outcome_reported_at IS NULL\n         AND ((state = 'approved' AND receipt_claimed_at IS NULL\n               AND ?1 IN ('failed', 'outcome_unknown', 'cancelled_before_effect', 'expired_before_effect'))\n              OR (state = 'outcome_unknown' AND receipt_claimed_at IS NOT NULL))",
                &[s(&state), s(&serialized_outcome), n(now), s(&id), s(&auth.uid)],
            )?,
            stmt(
                &db,
                "UPDATE currents SET status = ?1, updated_at = ?2\n       WHERE uid = ?3 AND status IN ('accepted', 'expired') AND id = (\n         SELECT current_id FROM current_executions\n         WHERE id = ?4 AND uid = ?3 AND state = ?5 AND outcome = ?6\n           AND outcome_reported_at = ?2 AND updated_at = ?2\n       )",
                &[s(current_status), n(now), s(&auth.uid), s(&id), s(&state), s(&serialized_outcome)],
            )?,
        ])
        .await?;
    if changes(&results[0]) != 1 {
        let stored = d1_first(
            &db,
            "SELECT state, outcome, outcome_reported_at FROM current_executions WHERE id = ?1 AND uid = ?2",
            &[s(&id), s(&auth.uid)],
        )
        .await?;
        let reported = stored
            .as_ref()
            .and_then(|r| r.get("outcome_reported_at"))
            .map(|v| !v.is_null())
            .unwrap_or(false);
        let stored_state = stored.as_ref().map(|r| str_field(r, "state"));
        let stored_outcome = stored.as_ref().map(|r| str_field(r, "outcome"));
        if !reported
            || stored_state.as_deref() != Some(state.as_str())
            || stored_outcome.as_deref() != Some(serialized_outcome.as_str())
        {
            return error_json("Execution is not awaiting this outcome", 409);
        }
    }
    Response::from_json(&json!({ "executionId": id, "state": state }))
}

/// Port of `createCurrent` (currents.ts) — the shared write behind the public
/// API `POST /api/v1/currents` and the `create_current` MCP tool.
///
/// When no evidence id is cited, a source/revision/evidence triple is
/// synthesised from the caller's `reason` so every Current still carries a
/// citation. When one *is* cited it must resolve, per-uid, to live evidence;
/// otherwise `None` (the TS `null` → 404 "Cited evidence not found").
pub(crate) async fn create_current(
    db: &D1Database,
    uid: &str,
    input: &crate::public_api::CurrentInput,
) -> Result<Option<Value>> {
    let now = now_ms();
    let evidence_id = match input.evidence_id.as_deref() {
        None => {
            let source_id = uuid_v4();
            let revision_id = uuid_v4();
            let evidence_id = uuid_v4();
            let payload = json!({ "title": input.title, "reason": input.reason }).to_string();
            db.batch(vec![
                stmt(
                    db,
                    "INSERT INTO memory_sources (id, uid, kind, created_at, updated_at) VALUES (?1, ?2, 'integration', ?3, ?3)",
                    &[s(&source_id), s(uid), n(now)],
                )?,
                stmt(
                    db,
                    "INSERT INTO memory_source_revisions\n                       (id, source_id, uid, revision, content_hash, payload, observed_at, created_at)\n                     VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?6)",
                    &[
                        s(&revision_id),
                        s(&source_id),
                        s(uid),
                        s(&sha256_hex(&input.reason)),
                        s(&payload),
                        n(now),
                    ],
                )?,
                stmt(
                    db,
                    "INSERT INTO memory_evidence (id, uid, source_revision_id, quote, locator, created_at) VALUES (?1, ?2, ?3, ?4, '[]', ?5)",
                    &[
                        s(&evidence_id),
                        s(uid),
                        s(&revision_id),
                        s(&input.reason),
                        n(now),
                    ],
                )?,
            ])
            .await?;
            evidence_id
        }
        Some(cited) => {
            let evidence = d1_first(
                db,
                "SELECT e.id FROM memory_evidence e\n     JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n     JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n     WHERE e.id = ?1 AND e.uid = ?2 AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL",
                &[s(cited), s(uid)],
            )
            .await?;
            if evidence.is_none() {
                return Ok(None);
            }
            cited.to_string()
        }
    };
    let id = uuid_v4();
    let proposed_action = json!({ "kind": "review", "instruction": input.instruction }).to_string();
    d1_run(
        db,
        "INSERT INTO currents\n      (id, uid, evidence_id, title, summary, reason, confidence_basis_points, proposed_action,\n       status, surface_at, expires_at, created_at, updated_at, crepus)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'candidate', ?9, ?10, ?11, ?11, ?12)",
        &[
            s(&id),
            s(uid),
            s(&evidence_id),
            s(&input.title),
            s(&input.summary),
            s(&input.reason),
            n((input.confidence * 10_000.0).round() as i64),
            s(&proposed_action),
            n(input.surface_at),
            nullable_n(input.expires_at),
            n(now),
            nullable_s(input.crepus.as_deref()),
        ],
    )
    .await?;
    Ok(select_current(db, uid, &id)
        .await?
        .map(|row| row_to_current(&row)))
}
