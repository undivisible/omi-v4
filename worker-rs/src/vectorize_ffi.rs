//! Hand-written JS FFI for the Cloudflare Vectorize index binding, which has no
//! native workers-rs wrapper in 0.8.5. Compiled only under
//! `--features vectorize` (and wasm). Mirrors the `MEMORY_VECTORS` usage in
//! `worker/src/memory-vectors.ts` plus the Workers AI embeddings in
//! `worker/src/embeddings.ts`.
//!
//! Interop strategy: values cross the boundary as JSON. Options/vectors are
//! built with `serde_json` then `JSON.parse`d into JS objects; results are
//! `JSON.stringify`d back into `serde_json::Value`. This keeps the binding
//! dependency-light (no `serde_wasm_bindgen` in this crate) and type-simple.

#![allow(dead_code)]

use serde_json::{json, Value};
use worker::js_sys::{Array, Function, Promise, Reflect, JSON};
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::wasm_bindgen_futures::JsFuture;
use worker::Env;

const EMBEDDING_MODEL: &str = "@cf/baai/bge-base-en-v1.5";
const MAX_INPUT_CHARS: usize = 2_000;
const SNIPPET_CHARS: usize = 300;
const CONTEXT_CHAR_CAP: usize = 2_000;
const TOP_K: u32 = 8;

/// Fetch the `MEMORY_VECTORS` binding as a raw JS object, or `None` when it is
/// unbound (parity with the `if (!env.MEMORY_VECTORS) return …` guards).
fn vectorize_index(env: &Env) -> Option<JsValue> {
    let value = Reflect::get(env, &JsValue::from_str("MEMORY_VECTORS")).ok()?;
    if value.is_undefined() || value.is_null() {
        None
    } else {
        Some(value)
    }
}

/// Await a method call `obj.method(...args)` that returns a Promise, yielding
/// the resolved JS value.
async fn call_method(obj: &JsValue, method: &str, args: &Array) -> Result<JsValue, JsValue> {
    let func: Function = Reflect::get(obj, &JsValue::from_str(method))?.dyn_into()?;
    let result = func.apply(obj, args)?;
    let promise: Promise = result.dyn_into()?;
    JsFuture::from(promise).await
}

fn to_js(value: &Value) -> Result<JsValue, JsValue> {
    JSON::parse(&value.to_string())
}

fn from_js(value: &JsValue) -> Option<Value> {
    let text = JSON::stringify(value).ok()?.as_string()?;
    serde_json::from_str(&text).ok()
}

/// `MEMORY_VECTORS.query(vector, options)`.
pub async fn query(
    env: &Env,
    vector: &[f64],
    uid: &str,
    top_k: u32,
) -> Option<Vec<(String, f64)>> {
    let index = vectorize_index(env)?;
    let vector_js = to_js(&json!(vector)).ok()?;
    let options = to_js(&json!({
        "topK": top_k,
        "filter": { "uid": uid },
        "returnValues": false,
        "returnMetadata": "none",
    }))
    .ok()?;
    let args = Array::new();
    args.push(&vector_js);
    args.push(&options);
    let result = call_method(&index, "query", &args).await.ok()?;
    let parsed = from_js(&result)?;
    let matches = parsed.get("matches")?.as_array()?;
    Some(
        matches
            .iter()
            .filter_map(|m| {
                let id = m.get("id").and_then(Value::as_str).filter(|s| !s.is_empty())?;
                let score = m.get("score").and_then(Value::as_f64).unwrap_or(0.0);
                Some((id.to_string(), score))
            })
            .collect(),
    )
}

/// `MEMORY_VECTORS.upsert(vectors)`. Each entry: {id, values, metadata}.
pub async fn upsert(env: &Env, vectors: &Value) -> Result<(), ()> {
    let index = vectorize_index(env).ok_or(())?;
    let vectors_js = to_js(vectors).map_err(|_| ())?;
    let args = Array::new();
    args.push(&vectors_js);
    call_method(&index, "upsert", &args).await.map_err(|_| ())?;
    Ok(())
}

/// `MEMORY_VECTORS.deleteByIds(ids)`.
pub async fn delete_by_ids(env: &Env, ids: &[String]) -> Result<(), ()> {
    let index = vectorize_index(env).ok_or(())?;
    let ids_js = to_js(&json!(ids)).map_err(|_| ())?;
    let args = Array::new();
    args.push(&ids_js);
    call_method(&index, "deleteByIds", &args)
        .await
        .map_err(|_| ())?;
    Ok(())
}

/// Port of `embedTexts`: run the Workers AI embedding model. `None` on any
/// failure or shape mismatch (parity with the TS null-guards).
pub async fn embed_texts(env: &Env, texts: &[String]) -> Option<Vec<Vec<f64>>> {
    if texts.is_empty() {
        return Some(Vec::new());
    }
    let ai = env.ai("AI").ok()?;
    let truncated: Vec<String> = texts
        .iter()
        .map(|t| t.chars().take(MAX_INPUT_CHARS).collect())
        .collect();
    let output: Value = ai
        .run(EMBEDDING_MODEL, json!({ "text": truncated }))
        .await
        .ok()?;
    let data = output.get("data")?.as_array()?;
    if data.len() != texts.len() {
        return None;
    }
    let mut vectors = Vec::with_capacity(data.len());
    for entry in data {
        let arr = entry.as_array()?;
        if arr.is_empty() {
            return None;
        }
        let mut vector = Vec::with_capacity(arr.len());
        for value in arr {
            vector.push(value.as_f64()?);
        }
        vectors.push(vector);
    }
    Some(vectors)
}

/// Port of `searchMemoryClaims`: embed the query, Vectorize `query`, then a D1
/// batch to resolve the still-eligible claim contents.
async fn search_memory_claims(
    env: &Env,
    uid: &str,
    query_text: &str,
) -> Vec<(String, String, f64)> {
    let Some(vectors) = embed_texts(env, &[query_text.to_string()]).await else {
        return Vec::new();
    };
    let Some(vector) = vectors.into_iter().next() else {
        return Vec::new();
    };
    let Some(matches) = query(env, &vector, uid, TOP_K).await else {
        return Vec::new();
    };
    if matches.is_empty() {
        return Vec::new();
    }
    let Ok(db) = env.d1("DB") else {
        return Vec::new();
    };
    let now = worker::Date::now().as_millis() as f64;
    let mut statements = Vec::with_capacity(matches.len());
    for (id, _) in &matches {
        let Ok(stmt) = db
            .prepare(
                "SELECT id, content FROM memory_claims\n                 WHERE id = ?1 AND uid = ?2\n                   AND status = 'accepted' AND retracted_at IS NULL\n                   AND (valid_from IS NULL OR valid_from <= ?3)\n                   AND (valid_to IS NULL OR valid_to > ?3)\n                   AND (recorded_until IS NULL OR recorded_until > ?3)\n                   AND (zkr_tier IS NULL OR zkr_tier != 'archive')\n                   AND (zkr_processing_state IS NULL OR zkr_processing_state = 'processed')",
            )
            .bind(&[id.as_str().into(), uid.into(), now.into()])
        else {
            return Vec::new();
        };
        statements.push(stmt);
    }
    let Ok(results) = db.batch(statements).await else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for ((id, score), result) in matches.iter().zip(results.iter()) {
        let rows: Vec<Value> = result.results::<Value>().unwrap_or_default();
        if let Some(row) = rows.first() {
            if let Some(content) = row.get("content").and_then(Value::as_str) {
                out.push((id.clone(), content.to_string(), *score));
            }
        }
    }
    out
}

/// Port of `memoryContextFor`: assemble a capped snippet block, or `None`.
pub async fn memory_context_for(env: &Env, uid: &str, query_text: &str) -> Option<String> {
    let items = search_memory_claims(env, uid, query_text).await;
    if items.is_empty() {
        return None;
    }
    let mut output = String::from("Relevant synced memory (server-retrieved, may be partial):");
    for (_, content, _) in &items {
        let snippet: String = content.chars().take(SNIPPET_CHARS).collect();
        let line = format!("\n- {snippet}");
        if output.len() + line.len() > CONTEXT_CHAR_CAP {
            break;
        }
        output.push_str(&line);
    }
    Some(output)
}
