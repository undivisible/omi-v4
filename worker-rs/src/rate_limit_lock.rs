//! `consumeRateLimit` / `acquireRefreshLock` / `releaseRefreshLock` helpers
//! (port of the same-named exports in `worker/src/rate-limit.ts`), calling
//! the shared `RATE_LIMITER` Durable Object.
//!
//! The DO itself (`RateLimiterDo`, implementing this exact `/consume`,
//! `/acquire-lock`, `/release-lock` protocol against `rate_limit::RateLimiter`)
//! lives in `routes_ai.rs` — the AI route group's port of the same TS file —
//! and is bound once in wrangler.toml under `RATE_LIMITER`. Kept as one
//! canonical implementation rather than two competing DO classes.

use serde_json::json;
use worker::wasm_bindgen::JsValue;
use worker::*;

fn stub_for(env: &Env, key: &str) -> Result<Stub> {
    env.durable_object("RATE_LIMITER")?.get_by_name(key)
}

fn post_init(body: &serde_json::Value) -> Result<RequestInit> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = worker::Headers::new();
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    Ok(init)
}

/// `consumeRateLimit` — returns `(allowed, retry_after)`.
pub async fn consume_rate_limit(
    env: &Env,
    key: &str,
    limit: u32,
    window_ms: u32,
) -> Result<(bool, i64)> {
    let init = post_init(&json!({ "limit": limit, "windowMs": window_ms }))?;
    let req = Request::new_with_init("https://rate-limit.internal/consume", &init)?;
    let mut response = stub_for(env, key)?.fetch_with_request(req).await?;
    let body: serde_json::Value = response.json().await.unwrap_or(serde_json::Value::Null);
    let allowed = body
        .get("allowed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let retry_after = body
        .get("retryAfter")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(1);
    Ok((allowed, retry_after))
}

/// `acquireRefreshLock` — true when the mutex was acquired (HTTP 200).
pub async fn acquire_refresh_lock(env: &Env, key: &str) -> Result<bool> {
    let init = post_init(&json!({ "ttlMs": 15_000 }))?;
    let req = Request::new_with_init("https://rate-limit.internal/acquire-lock", &init)?;
    let response = stub_for(env, key)?.fetch_with_request(req).await?;
    Ok(response.status_code() == 200)
}

/// `releaseRefreshLock`.
pub async fn release_refresh_lock(env: &Env, key: &str) -> Result<()> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let req = Request::new_with_init("https://rate-limit.internal/release-lock", &init)?;
    let _ = stub_for(env, key)?.fetch_with_request(req).await;
    Ok(())
}
