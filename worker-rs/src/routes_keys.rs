//! workers-rs I/O layer for the API-key and BYOK-negotiation route groups.
//! Compiled only for wasm32. Behaviour parity with `worker/src/api-keys.ts`
//! and `worker/src/byok-negotiation.ts`.
//!
//! This module also owns [`require_api_access`], the credential gate shared by
//! the public API (`/api/v1/*`) and the MCP transport (`/mcp`): a request may
//! present either an `omi_sk_` API key or, unchanged, a Firebase ID token.

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::{Headers, Method, Request, RequestInit, Response, Result, RouteContext, Router};

use crate::api_keys::{self, Credential, KeyCandidate};
use crate::byok_negotiation as byok;
use crate::byok_pricing::{self, PriceBand};
use crate::glue::{authenticate, error_json, json_to_i64, AuthOutcome};
use crate::managed_ai;
use crate::routes_ai::consume_rate_limit;
use crate::routes_memory::wasm_glue::{d1_all, d1_first, d1_run, n, nullable_n, s, str_field};
use crate::worker_util::{changes, now_ms, secret_or_var as env_get, uuid_v4};

/// Register the API-key and BYOK routes on the shared glue router. Both groups
/// sit behind the first-party Firebase `requireAuth` gate, exactly as the TS
/// mounts them under `/v1/*`.
pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .get_async("/v1/api-keys", handle_keys_list)
        .post_async("/v1/api-keys", handle_keys_create)
        .delete_async("/v1/api-keys/:id", handle_keys_delete)
        .get_async("/v1/byok/plan", handle_plan_get)
        .post_async("/v1/byok/plan/standard", handle_plan_standard)
        .post_async("/v1/byok/negotiation", handle_negotiation_start)
        .post_async(
            "/v1/byok/negotiation/:id/message",
            handle_negotiation_message,
        )
        .post_async("/v1/byok/negotiation/:id/accept", handle_negotiation_accept)
}

fn json_status(body: &Value, status: u16) -> Result<Response> {
    Ok(Response::from_json(body)?.with_status(status))
}

fn retry_after_json(body: &Value, status: u16, retry_after: i64) -> Result<Response> {
    let headers = Headers::new();
    headers.set("retry-after", &retry_after.to_string())?;
    Ok(Response::from_json(body)?
        .with_status(status)
        .with_headers(headers))
}

async fn json_body(req: &mut Request) -> Option<Value> {
    req.json::<Value>().await.ok().filter(Value::is_object)
}

// ---------------------------------------------------------------------------
// Credential gate shared with the public API and MCP
// ---------------------------------------------------------------------------

/// The API-key context attached to a request (`context.get("apiKey")`).
pub(crate) struct ApiKeyContext {
    pub(crate) id: String,
    pub(crate) scopes: Vec<String>,
}

/// The authenticated caller on the programmatic surface. `key` is `None` for a
/// Firebase-authenticated caller, who is the account owner in person and
/// therefore carries every scope.
pub(crate) struct ApiAuth {
    pub(crate) uid: String,
    pub(crate) email: Option<String>,
    pub(crate) key: Option<ApiKeyContext>,
}

impl ApiAuth {
    /// `null` for Firebase (every scope), the minted list for an API key.
    pub(crate) fn scopes(&self) -> Option<&[String]> {
        self.key.as_ref().map(|key| key.scopes.as_slice())
    }
}

/// Port of `verifyApiKey`. Candidates are selected by public prefix with
/// revocation and expiry enforced in SQL; the presented digest is then compared
/// against every candidate in constant time with no early exit.
pub(crate) async fn verify_api_key(
    ctx: &RouteContext<()>,
    token: &str,
    now: i64,
) -> Result<Option<ApiAuth>> {
    let Some(prefix) = api_keys::parse_key(token) else {
        return Ok(None);
    };
    let db = ctx.env.d1("DB")?;
    let rows = d1_all(
        &db,
        "SELECT k.id, k.uid, k.key_hash, k.scopes, u.email\n       FROM api_keys k JOIN users u ON u.uid = k.uid\n       WHERE k.prefix = ?1 AND k.revoked_at IS NULL\n         AND (k.expires_at IS NULL OR k.expires_at > ?2)",
        &[s(prefix), n(now)],
    )
    .await?;
    let candidates: Vec<KeyCandidate> = rows
        .iter()
        .map(|row| KeyCandidate {
            id: str_field(row, "id"),
            uid: str_field(row, "uid"),
            key_hash: str_field(row, "key_hash"),
            scopes: api_keys::parse_scopes(row.get("scopes")),
            email: match row.get("email") {
                Some(Value::String(email)) => Some(email.clone()),
                _ => None,
            },
        })
        .collect();
    let presented = api_keys::digest(token);
    let Some(matched) = api_keys::select_match(&presented, &candidates) else {
        return Ok(None);
    };
    // Best-effort, minute-resolution last-use stamp; a failure here must never
    // fail the request (the TS `.catch(() => undefined)`).
    let _ = d1_run(
        &db,
        "UPDATE api_keys SET last_used_at = ?1\n       WHERE id = ?2 AND (last_used_at IS NULL OR last_used_at < ?3)",
        &[
            n(now),
            s(&matched.id),
            n(now - api_keys::LAST_USED_RESOLUTION_MS),
        ],
    )
    .await;
    Ok(Some(ApiAuth {
        uid: matched.uid.clone(),
        email: matched.email.clone(),
        key: Some(ApiKeyContext {
            id: matched.id.clone(),
            scopes: matched.scopes.clone(),
        }),
    }))
}

/// Port of `requireApiAccess`.
pub(crate) async fn require_api_access(
    req: &Request,
    ctx: &RouteContext<()>,
) -> std::result::Result<ApiAuth, Response> {
    let header = |name: &str| req.headers().get(name).ok().flatten().unwrap_or_default();
    let credential = api_keys::credential(&header("authorization"), &header("x-api-key"));
    let token = match credential {
        Credential::Firebase => {
            return match authenticate(req, ctx).await {
                AuthOutcome::Ok(auth) => Ok(ApiAuth {
                    uid: auth.uid,
                    email: auth.email,
                    key: None,
                }),
                AuthOutcome::Reject(response) => Err(response),
            }
        }
        Credential::ApiKey(token) => token,
    };
    let fallback = |message: &str, status: u16| {
        error_json(message, status).unwrap_or_else(|_| {
            Response::empty()
                .expect("empty response")
                .with_status(status)
        })
    };
    match verify_api_key(ctx, &token, now_ms()).await {
        Err(_) => Err(fallback("Authentication unavailable", 503)),
        Ok(None) => Err(fallback("Authentication failed", 401)),
        Ok(Some(auth)) => Ok(auth),
    }
}

/// Port of `requireScope`: a Firebase caller passes, an API key must carry it.
pub(crate) fn require_scope(auth: &ApiAuth, scope: &str) -> Option<Result<Response>> {
    let scopes = auth.scopes()?;
    if scopes.iter().any(|held| held == scope) {
        return None;
    }
    Some(json_status(
        &json!({ "error": "Missing scope", "scope": scope }),
        403,
    ))
}

// ---------------------------------------------------------------------------
// /v1/api-keys
// ---------------------------------------------------------------------------

const KEY_COLUMNS: &str =
    "SELECT id, name, prefix, scopes, created_at, last_used_at, expires_at, revoked_at";

/// `rowToKey` — the public projection. The secret is never in this shape.
fn row_to_key(row: &Value) -> Value {
    let nullable = |key: &str| row.get(key).and_then(json_to_i64);
    json!({
        "id": str_field(row, "id"),
        "name": str_field(row, "name"),
        "prefix": format!("{}{}", api_keys::API_KEY_PREFIX, str_field(row, "prefix")),
        "scopes": api_keys::parse_scopes(row.get("scopes")),
        "createdAt": row.get("created_at").and_then(json_to_i64).unwrap_or(0),
        "lastUsedAt": nullable("last_used_at"),
        "expiresAt": nullable("expires_at"),
        "revokedAt": nullable("revoked_at"),
    })
}

macro_rules! firebase {
    ($req:expr, $ctx:expr) => {
        match authenticate(&$req, &$ctx).await {
            AuthOutcome::Ok(auth) => auth,
            AuthOutcome::Reject(response) => return Ok(response),
        }
    };
}

async fn handle_keys_list(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let db = ctx.env.d1("DB")?;
    let rows = d1_all(
        &db,
        &format!(
            "{KEY_COLUMNS}\n     FROM api_keys WHERE uid = ?1 ORDER BY created_at DESC LIMIT 100"
        ),
        &[s(&auth.uid)],
    )
    .await?;
    let keys: Vec<Value> = rows.iter().map(row_to_key).collect();
    Response::from_json(&json!({ "keys": keys }))
}

async fn handle_keys_create(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let body = json_body(&mut req).await;
    let now = now_ms();
    let Some(request) = api_keys::validate_mint(body.as_ref(), now) else {
        return error_json("Invalid API key request", 400);
    };
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("api-key-mint:{}", auth.uid),
        api_keys::MINT_RATE_LIMIT,
        api_keys::MINT_RATE_WINDOW_MS,
    )
    .await;
    if !allowed {
        return retry_after_json(&json!({ "error": "Too many requests" }), 429, retry_after);
    }
    let db = ctx.env.d1("DB")?;
    let live = d1_first(
        &db,
        "SELECT COUNT(*) AS total FROM api_keys WHERE uid = ?1 AND revoked_at IS NULL",
        &[s(&auth.uid)],
    )
    .await?;
    let total = live
        .as_ref()
        .and_then(|row| row.get("total"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    if total >= api_keys::MAXIMUM_KEYS_PER_UID {
        return error_json("API key limit reached", 409);
    }
    let mut prefix_bytes = [0u8; 4];
    let mut secret_bytes = [0u8; 32];
    getrandom::getrandom(&mut prefix_bytes).expect("getrandom");
    getrandom::getrandom(&mut secret_bytes).expect("getrandom");
    let minted = api_keys::mint_api_key(prefix_bytes, secret_bytes);
    let id = uuid_v4();
    d1_run(
        &db,
        "INSERT INTO api_keys (id, uid, name, prefix, key_hash, scopes, created_at, expires_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        &[
            s(&id),
            s(&auth.uid),
            s(&request.name),
            s(&minted.prefix),
            s(&minted.hash),
            s(&Value::from(request.scopes.clone()).to_string()),
            n(now),
            nullable_n(request.expires_at),
        ],
    )
    .await?;
    let stored = d1_first(
        &db,
        &format!("{KEY_COLUMNS}\n     FROM api_keys WHERE id = ?1 AND uid = ?2"),
        &[s(&id), s(&auth.uid)],
    )
    .await?
    .unwrap_or(Value::Null);
    // The plaintext key is returned exactly once; only its digest is retained.
    json_status(
        &json!({ "key": minted.key, "apiKey": row_to_key(&stored) }),
        201,
    )
}

async fn handle_keys_delete(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let db = ctx.env.d1("DB")?;
    // Revocation is scoped to the owner and is idempotent-safe: a second
    // delete changes no rows and answers 404.
    let revoked = d1_run(
        &db,
        "UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND uid = ?3 AND revoked_at IS NULL",
        &[n(now_ms()), s(&id), s(&auth.uid)],
    )
    .await?;
    if changes(&revoked) != 1 {
        return error_json("API key not found", 404);
    }
    Ok(Response::empty()?.with_status(204))
}

// ---------------------------------------------------------------------------
// /v1/byok
// ---------------------------------------------------------------------------

fn band_for(ctx: &RouteContext<()>) -> PriceBand {
    byok_pricing::price_band(|name| env_get(&ctx.env, name))
}

/// Port of `agreedByokPrice`: the recorded price for a user, read straight
/// from the audit record and clamped into the band in force today.
async fn agreed_price(
    ctx: &RouteContext<()>,
    band: &PriceBand,
    uid: &str,
) -> Result<Option<byok::AgreedPrice>> {
    let db = ctx.env.d1("DB")?;
    let row = d1_first(
        &db,
        "SELECT price_cents, outcome, agreed_at FROM byok_price_agreements WHERE uid = ?1",
        &[s(uid)],
    )
    .await?;
    Ok(row.map(|row| {
        byok::clamp_agreement(
            band,
            row.get("price_cents").and_then(json_to_i64).unwrap_or(0),
            &str_field(&row, "outcome"),
            row.get("agreed_at").and_then(json_to_i64).unwrap_or(0),
        )
    }))
}

#[allow(clippy::too_many_arguments)]
async fn upsert_agreement(
    ctx: &RouteContext<()>,
    uid: &str,
    session_id: Option<&str>,
    outcome: &str,
    price_cents: i64,
    band: &PriceBand,
    grants: &[String],
    transcript: &[byok::TranscriptEntry],
    now: i64,
) -> Result<()> {
    let db = ctx.env.d1("DB")?;
    let transcript_json =
        Value::Array(transcript.iter().map(|e| e.to_value()).collect()).to_string();
    d1_run(
        &db,
        "INSERT INTO byok_price_agreements\n       (uid, session_id, outcome, price_cents, standard_price_cents, floor_price_cents,\n        grants, transcript, agreed_at, created_at, updated_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9)\n     ON CONFLICT(uid) DO UPDATE SET\n       session_id = excluded.session_id,\n       outcome = excluded.outcome,\n       price_cents = excluded.price_cents,\n       standard_price_cents = excluded.standard_price_cents,\n       floor_price_cents = excluded.floor_price_cents,\n       grants = excluded.grants,\n       transcript = excluded.transcript,\n       agreed_at = excluded.agreed_at,\n       updated_at = excluded.updated_at",
        &[
            s(uid),
            session_id.map(s).unwrap_or(JsValue::NULL),
            s(outcome),
            n(price_cents),
            n(band.standard_cents),
            n(band.floor_cents),
            s(&Value::from(grants.to_vec()).to_string()),
            s(&transcript_json),
            n(now),
        ],
    )
    .await?;
    Ok(())
}

async fn handle_plan_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let band = band_for(&ctx);
    let agreement = agreed_price(&ctx, &band, &auth.uid).await?;
    Response::from_json(&byok::plan_payload(&band, agreement.as_ref(), now_ms()))
}

// Taking the standard price is always available and is recorded like any
// other outcome, so skipping is a first-class path rather than a dead end.
async fn handle_plan_standard(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let band = band_for(&ctx);
    let now = now_ms();
    upsert_agreement(
        &ctx,
        &auth.uid,
        None,
        "standard",
        band.standard_cents,
        &band,
        &[],
        &[],
        now,
    )
    .await?;
    let agreement = agreed_price(&ctx, &band, &auth.uid).await?;
    json_status(&byok::plan_payload(&band, agreement.as_ref(), now), 201)
}

async fn handle_negotiation_start(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let band = band_for(&ctx);
    let now = now_ms();
    let agreement = agreed_price(&ctx, &band, &auth.uid).await?;
    // Renegotiation is bounded twice: by the recorded agreement's cooldown and
    // by a rate limiter, so repeat attempts cannot be farmed for a lower price.
    if let Some(agreement) = agreement.as_ref() {
        if now < agreement.agreed_at + band.cooldown_ms {
            let mut body = byok::plan_payload(&band, Some(agreement), now);
            let mut merged = json!({ "error": "Price already agreed" });
            if let (Some(target), Some(source)) = (merged.as_object_mut(), body.as_object_mut()) {
                for (key, value) in source.iter() {
                    target.insert(key.clone(), value.clone());
                }
            }
            return json_status(&merged, 409);
        }
    }
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("byok-negotiation-start:{}", auth.uid),
        byok::SESSION_START_LIMIT,
        byok::SESSION_START_WINDOW_MS,
    )
    .await;
    if !allowed {
        return retry_after_json(
            &json!({ "error": "Too many negotiations" }),
            429,
            retry_after,
        );
    }
    if env_get(&ctx.env, "MIMO_API_KEY").is_none()
        || env_get(&ctx.env, "MIMO_CHAT_COMPLETIONS_URL").is_none()
    {
        return error_json("Negotiation unavailable", 503);
    }
    let id = uuid_v4();
    let opening = byok::opening_entry(&band);
    let db = ctx.env.d1("DB")?;
    d1_run(
        &db,
        "INSERT INTO byok_negotiation_sessions\n       (id, uid, status, turns, standard_price_cents, floor_price_cents, price_cents,\n        grants, transcript, created_at, updated_at)\n     VALUES (?1, ?2, 'open', 0, ?3, ?4, ?3, '[]', ?5, ?6, ?6)",
        &[
            s(&id),
            s(&auth.uid),
            n(band.standard_cents),
            n(band.floor_cents),
            s(&Value::Array(vec![opening.to_value()]).to_string()),
            n(now),
        ],
    )
    .await?;
    json_status(
        &json!({
            "sessionId": id,
            "priceCents": band.standard_cents,
            "standardPriceCents": band.standard_cents,
            "turnsRemaining": band.max_turns,
            "transcript": [opening.to_value()],
        }),
        201,
    )
}

struct SessionRow {
    id: String,
    status: String,
    turns: i64,
    grants: Value,
    transcript: Value,
}

/// A session is only ever loaded scoped to the calling uid, so another user's
/// negotiation is not reachable at all.
async fn load_session(ctx: &RouteContext<()>, uid: &str, id: &str) -> Result<Option<SessionRow>> {
    let db = ctx.env.d1("DB")?;
    let row = d1_first(
        &db,
        "SELECT id, uid, status, turns, grants, transcript FROM byok_negotiation_sessions WHERE id = ?1 AND uid = ?2",
        &[s(id), s(uid)],
    )
    .await?;
    Ok(row.map(|row| SessionRow {
        id: str_field(&row, "id"),
        status: str_field(&row, "status"),
        turns: row.get("turns").and_then(json_to_i64).unwrap_or(0),
        grants: row.get("grants").cloned().unwrap_or(Value::Null),
        transcript: row.get("transcript").cloned().unwrap_or(Value::Null),
    }))
}

/// Port of `callModel`. The reply is a *suggestion*: it is parsed, clamped and
/// sanitised by the caller, and never sets a price.
async fn call_model(
    ctx: &RouteContext<()>,
    band: &PriceBand,
    granted: &[String],
    transcript: &[byok::TranscriptEntry],
) -> Option<String> {
    let endpoint = env_get(&ctx.env, "MIMO_CHAT_COMPLETIONS_URL")?;
    let secret = env_get(&ctx.env, "MIMO_API_KEY")?;
    let endpoint_url = managed_ai::validate_pinned_endpoint(
        &endpoint,
        managed_ai::XIAOMI_COMPLETION_ENDPOINT,
        managed_ai::XIAOMI_HOSTNAME,
    )?;
    let model = managed_ai::model_for_tier(managed_ai::ModelTier::Balanced, |name| {
        env_get(&ctx.env, name)
    });
    let mut messages = vec![json!({
        "role": "system",
        "content": byok::system_prompt(band, granted),
    })];
    messages.extend(transcript.iter().map(|entry| {
        json!({
            "role": if entry.role == "user" { "user" } else { "assistant" },
            "content": entry.content,
        })
    }));
    let body = json!({
        "model": model,
        "stream": false,
        "max_tokens": 400,
        "temperature": 0.7,
        "messages": messages,
    });
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers
        .set("authorization", &format!("Bearer {secret}"))
        .ok()?;
    headers.set("content-type", "application/json").ok()?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let request = Request::new_with_init(endpoint_url.as_str(), &init).ok()?;
    let mut upstream = worker::Fetch::Request(request).send().await.ok()?;
    if upstream.status_code() >= 300 {
        return None;
    }
    let completion = upstream.json::<Value>().await.ok()?;
    completion
        .get("choices")?
        .get(0)?
        .get("message")?
        .get("content")?
        .as_str()
        .map(str::to_string)
}

async fn handle_negotiation_message(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let band = band_for(&ctx);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let Some(session) = load_session(&ctx, &auth.uid, &id).await? else {
        return error_json("Unknown negotiation", 404);
    };
    if session.status != "open" {
        return error_json("Negotiation closed", 409);
    }
    let body = bounded_json(&mut req, byok::MAXIMUM_BODY_BYTES).await;
    let Some(message) = byok::validate_message(body.as_ref()) else {
        return error_json("Invalid request", 400);
    };
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("byok-negotiation-message:{}", auth.uid),
        byok::MESSAGE_LIMIT,
        byok::MESSAGE_WINDOW_MS,
    )
    .await;
    if !allowed {
        return retry_after_json(&json!({ "error": "Too many messages" }), 429, retry_after);
    }
    if session.turns >= band.max_turns {
        return error_json("Negotiation closed", 409);
    }
    let granted =
        byok_pricing::normalize_grants(&band, &byok::parse_json_array(Some(&session.grants)));
    let mut transcript = byok::parse_transcript(Some(&session.transcript));
    if transcript.len() > byok::MAXIMUM_TRANSCRIPT_ENTRIES {
        transcript = transcript.split_off(transcript.len() - byok::MAXIMUM_TRANSCRIPT_ENTRIES);
    }
    transcript.push(byok::TranscriptEntry {
        role: "user".to_string(),
        content: message,
    });
    let raw = call_model(&ctx, &band, &granted, &transcript).await;
    let suggestion = raw
        .as_deref()
        .and_then(|raw| byok::parse_suggestion(&band, &granted, raw));
    let Some(suggestion) = suggestion else {
        return error_json("Negotiation unavailable", 502);
    };
    let mut grants = granted.clone();
    if let Some(concession) = suggestion.concession.as_ref() {
        grants.push(concession.code.to_string());
    }
    // The price is computed here, from the server-side band, and never read
    // from the model output or the request body.
    let price_cents = byok_pricing::price_for_grants(&band, &grants);
    let reply = byok::sanitize_reply(&suggestion.reply, price_cents);
    transcript.push(byok::TranscriptEntry {
        role: "omi".to_string(),
        content: reply.clone(),
    });
    let turns = session.turns + 1;
    let now = now_ms();
    let db = ctx.env.d1("DB")?;
    d1_run(
        &db,
        "UPDATE byok_negotiation_sessions\n       SET turns = ?1, grants = ?2, transcript = ?3, price_cents = ?4, updated_at = ?5\n     WHERE id = ?6 AND uid = ?7",
        &[
            n(turns),
            s(&Value::from(grants).to_string()),
            s(&Value::Array(transcript.iter().map(|e| e.to_value()).collect()).to_string()),
            n(price_cents),
            n(now),
            s(&session.id),
            s(&auth.uid),
        ],
    )
    .await?;
    Response::from_json(&json!({
        "reply": reply,
        "priceCents": price_cents,
        "standardPriceCents": band.standard_cents,
        "turnsRemaining": (band.max_turns - turns).max(0),
        "conceded": suggestion.concession.is_some(),
    }))
}

// Accepting recomputes the price from the stored grants rather than trusting
// anything in the request, so a replayed or edited accept settles at exactly
// the same figure the conversation earned.
async fn handle_negotiation_accept(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = firebase!(req, ctx);
    let band = band_for(&ctx);
    let id = ctx.param("id").cloned().unwrap_or_default();
    let Some(session) = load_session(&ctx, &auth.uid, &id).await? else {
        return error_json("Unknown negotiation", 404);
    };
    let now = now_ms();
    if session.status == "agreed" {
        let agreement = agreed_price(&ctx, &band, &auth.uid).await?;
        return Response::from_json(&byok::plan_payload(&band, agreement.as_ref(), now));
    }
    if session.status != "open" {
        return error_json("Negotiation closed", 409);
    }
    let grants =
        byok_pricing::normalize_grants(&band, &byok::parse_json_array(Some(&session.grants)));
    let price_cents = byok_pricing::price_for_grants(&band, &grants);
    let db = ctx.env.d1("DB")?;
    d1_run(
        &db,
        "UPDATE byok_negotiation_sessions SET status = 'agreed', price_cents = ?1, updated_at = ?2 WHERE id = ?3 AND uid = ?4",
        &[n(price_cents), n(now), s(&session.id), s(&auth.uid)],
    )
    .await?;
    upsert_agreement(
        &ctx,
        &auth.uid,
        Some(&session.id),
        if price_cents < band.standard_cents {
            "negotiated"
        } else {
            "standard"
        },
        price_cents,
        &band,
        &grants,
        &byok::parse_transcript(Some(&session.transcript)),
        now,
    )
    .await?;
    let agreement = agreed_price(&ctx, &band, &auth.uid).await?;
    json_status(&byok::plan_payload(&band, agreement.as_ref(), now), 201)
}

/// Port of `boundedJson`: a declared `content-length` over the limit is refused
/// outright, and the decoded body is refused when it exceeds the limit.
///
/// DEVIATION: workers-rs exposes the body as a whole rather than as a reader,
/// so an oversized chunked body is rejected after buffering rather than during
/// it. The accept/reject decision is identical; only the point of refusal
/// differs.
pub(crate) async fn bounded_json(req: &mut Request, limit: usize) -> Option<Value> {
    if let Some(declared) = req
        .headers()
        .get("content-length")
        .ok()
        .flatten()
        .and_then(|value| value.trim().parse::<usize>().ok())
    {
        if declared > limit {
            return None;
        }
    }
    let text = req.text().await.ok()?;
    if text.len() > limit {
        return None;
    }
    serde_json::from_str::<Value>(&text)
        .ok()
        .filter(Value::is_object)
}
