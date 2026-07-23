//! Self-contained port of `worker/src/rate-limit.ts` — the `RateLimiter`
//! Durable Object (fixed-window counter + short-lived refresh mutex) and the
//! `consumeRateLimit` / `acquireRefreshLock` / `releaseRefreshLock` helpers.
//!
//! MERGE NOTE: this is a deliberately self-contained copy so the delivery/oauth
//! group builds without depending on another worktree's port of `rate-limit.ts`.
//! If the rate-limit group also lands a `RateLimiter`, dedupe at merge (keep one
//! `#[durable_object]` struct + one `[[durable_objects.bindings]]` entry).

use serde::{Deserialize, Serialize};
use serde_json::json;
use worker::wasm_bindgen::JsValue;
use worker::*;

const DEFAULT_LIMIT: f64 = 60.0;
const DEFAULT_WINDOW_MS: f64 = 60_000.0;
const DEFAULT_LOCK_TTL_MS: f64 = 15_000.0;

#[derive(Serialize, Deserialize, Clone, Copy)]
struct Window {
    count: f64,
    #[serde(rename = "windowStart")]
    window_start: f64,
}

#[durable_object]
pub struct RateLimiter {
    state: State,
    #[allow(dead_code)]
    env: Env,
}

impl DurableObject for RateLimiter {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return Ok(Response::empty()?.with_status(405));
        }
        let path = req.path();
        match path.as_str() {
            "/consume" => self.consume(&mut req).await,
            "/acquire-lock" => self.acquire_lock(&mut req).await,
            "/release-lock" => self.release_lock().await,
            _ => Ok(Response::empty()?.with_status(404)),
        }
    }
}

impl RateLimiter {
    async fn consume(&self, req: &mut Request) -> Result<Response> {
        let body: serde_json::Value = req.json().await.unwrap_or(serde_json::Value::Null);
        let limit = positive_number(body.get("limit")).unwrap_or(DEFAULT_LIMIT);
        let window_ms = positive_number(body.get("windowMs")).unwrap_or(DEFAULT_WINDOW_MS);
        let now = js_now();
        let stored: Option<Window> = self.state.storage().get("window").await.ok().flatten();
        let start_new_window = match stored {
            None => true,
            Some(w) => now - w.window_start >= window_ms,
        };
        let window_start = if start_new_window {
            now
        } else {
            stored.map(|w| w.window_start).unwrap_or(now)
        };
        let count = if start_new_window {
            1.0
        } else {
            stored.map(|w| w.count).unwrap_or(0.0) + 1.0
        };
        self.state
            .storage()
            .put("window", Window { count, window_start })
            .await?;
        let allowed = count <= limit;
        let retry_after = (((window_start + window_ms - now) / 1000.0).ceil()).max(1.0) as i64;
        let response = Response::from_json(&json!({ "allowed": allowed, "retryAfter": retry_after }))?;
        let mut response = response.with_status(if allowed { 200 } else { 429 });
        if !allowed {
            response
                .headers_mut()
                .set("retry-after", &retry_after.to_string())?;
        }
        Ok(response)
    }

    async fn acquire_lock(&self, req: &mut Request) -> Result<Response> {
        let body: serde_json::Value = req.json().await.unwrap_or(serde_json::Value::Null);
        let ttl_ms = positive_number(body.get("ttlMs")).unwrap_or(DEFAULT_LOCK_TTL_MS);
        let now = js_now();
        let lock_until: Option<f64> = self.state.storage().get("lockUntil").await.ok().flatten();
        if let Some(until) = lock_until {
            if until > now {
                return Ok(Response::from_json(&json!({ "acquired": false }))?.with_status(409));
            }
        }
        self.state
            .storage()
            .put("lockUntil", now + ttl_ms)
            .await?;
        Response::from_json(&json!({ "acquired": true }))
    }

    async fn release_lock(&self) -> Result<Response> {
        self.state.storage().delete("lockUntil").await?;
        Response::from_json(&json!({ "released": true }))
    }
}

fn positive_number(value: Option<&serde_json::Value>) -> Option<f64> {
    value
        .and_then(serde_json::Value::as_f64)
        .filter(|n| *n > 0.0)
}

fn js_now() -> f64 {
    worker::Date::now().as_millis() as f64
}

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
    let allowed = body.get("allowed").and_then(serde_json::Value::as_bool).unwrap_or(false);
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
