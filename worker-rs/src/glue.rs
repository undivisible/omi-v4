//! workers-rs glue: routing, bindings, and the thin I/O layer around the pure
//! logic modules. Compiled only for wasm32. Behaviour parity with
//! `worker/src/index.ts` + the ported handlers in `worker/src/routes.ts`.

use std::cell::RefCell;

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::{
    event, Context, Date, Env, Fetch, Request, Response, Result, RouteContext, Router, Url,
};

use crate::auth::{self, Auth, FirebaseJwks};
use crate::entitlement::{self, DevFakePro, EntitlementRow};
use crate::setup_health::{setup_health_body, SetupHealthInputs};
use crate::{billing, conversations as conv, crypto_util, desktop_auth, webhooks as wh};

const JWKS_URL: &str =
    "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

thread_local! {
    // Per-isolate JWKS cache: (expires_at_ms, keys). Mirrors the module-level
    // `keys` cache in auth.ts.
    static JWKS_CACHE: RefCell<Option<(f64, Vec<auth::FirebaseJwk>)>> = const { RefCell::new(None) };
}

#[event(start)]
fn start() {
    console_error_panic_hook::set_once();
}

// Scheduled cron handler — parity with the TS `index.ts` minutely cron, which
// runs `Promise.all([deliverDueChannelMessages, respondToStaleInboxItems,
// reconcileManagedAssistantRequests, backfillClaimVectors→drainPendingEmbeddings])`.
// workers-rs Router handlers do not receive the execution `Context`, so the
// TS `waitUntil` deferral is awaited inline here; each slice fails independently
// (errors ignored, matching the TS `.catch(() => undefined)` on each branch).
#[event(scheduled)]
async fn scheduled(_event: worker::ScheduledEvent, env: Env, _ctx: worker::ScheduleContext) {
    // --- Delivery group: deliver due channel messages ---
    let _ = crate::routes_channels::deliver_due_channel_messages(&env).await;
    // --- Inbox fallback responder: reply to unclaimed inbox items ---
    let _ = crate::routes_channels::respond_to_stale_inbox_items(&env).await;
    // --- Managed AI: reconcile in-flight/streaming assistant requests ---
    let _ = crate::routes_ai::reconcile_managed_assistant_requests(&env).await;
    // --- Memory & Currents group: backfillClaimVectors → drainPendingEmbeddings ---
    crate::routes_memory::cron_slice(&env).await;
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let router = Router::new()
        .get("/health", |_req, _ctx| {
            Response::from_json(&json!({ "service": "omi-v4-api", "status": "ok" }))
        })
        .get_async("/v1/me", handle_me)
        .get_async("/v1/setup-health", handle_setup_health)
        .get_async("/v1/entitlement", handle_entitlement)
        .get_async("/v1/profile/onboarding", handle_onboarding_get)
        .put_async("/v1/profile/onboarding", handle_onboarding_put)
        .delete_async("/v1/account", handle_account_delete)
        // Phase 2: unauthenticated inbound webhooks (own auth: secret header /
        // HMAC). Mounted before the `/v1/*` auth guard in the TS worker.
        .post_async("/v1/webhooks/telegram", handle_webhook_telegram)
        .post_async("/v1/webhooks/blooio", handle_webhook_blooio)
        .post_async("/v1/webhooks/stripe", handle_webhook_stripe)
        // Phase 2: desktop auth handoff (no `/v1/*` middleware; /complete does
        // its own Firebase verification internally).
        .post_async("/v1/auth/desktop/start", handle_desktop_start)
        .post_async("/v1/auth/desktop/complete", handle_desktop_complete)
        .post_async("/v1/auth/desktop/exchange", handle_desktop_exchange)
        // Phase 2: billing (authenticated).
        .post_async("/v1/payments/stripe/checkout", handle_billing_checkout)
        .post_async("/v1/payments/stripe/portal", handle_billing_portal)
        // Phase 2: conversations (authenticated).
        .post_async("/v1/conversations/default/inbox/claim", handle_inbox_claim)
        .post_async(
            "/v1/conversations/default/inbox/:id/complete",
            handle_inbox_complete,
        )
        .get_async("/v1/conversations/default/messages", handle_messages_get)
        .post_async("/v1/conversations/default/messages", handle_messages_post)
        .put_async(
            "/v1/conversations/default/cursors/:clientId",
            handle_cursor_put,
        );
    // MERGE SEAM: each module group extends the router through its own
    // `register` hook.
    let router = crate::routes_channels::register(router);
    let router = crate::routes_ai::register(router);
    let router = crate::routes_memory::register(router);
    router
        .or_else_any_method("/*catchall", |_req, _ctx| {
            error_json("Not found", 404)
        })
        .run(req, env)
        .await
}

pub(crate) fn error_json(message: &str, status: u16) -> Result<Response> {
    Ok(Response::from_json(&json!({ "error": message }))?.with_status(status))
}

/// Fetch the Firebase JWKS, honouring the per-isolate cache and Cache-Control
/// max-age (parity with `firebaseKeys` in auth.ts).
async fn firebase_keys() -> Result<Vec<auth::FirebaseJwk>> {
    let now = Date::now().as_millis() as f64;
    if let Some(keys) = JWKS_CACHE.with(|cache| {
        cache
            .borrow()
            .as_ref()
            .filter(|(expires_at, _)| *expires_at > now)
            .map(|(_, values)| values.clone())
    }) {
        return Ok(keys);
    }

    let url = Url::parse(JWKS_URL).map_err(|e| worker::Error::RustError(e.to_string()))?;
    let mut response = Fetch::Url(url).send().await?;
    if response.status_code() != 200 {
        return Err(worker::Error::RustError("Firebase keys unavailable".into()));
    }
    let max_age = response
        .headers()
        .get("cache-control")
        .ok()
        .flatten()
        .map(|value| auth::cache_max_age(&value))
        .unwrap_or(300);
    let body: FirebaseJwks = response.json().await?;
    let expires_at = now + (max_age as f64) * 1000.0;
    let keys = body.keys;
    JWKS_CACHE.with(|cache| {
        *cache.borrow_mut() = Some((expires_at, keys.clone()));
    });
    Ok(keys)
}

/// Result of the auth middleware: an authenticated identity, or a Response to
/// short-circuit with (status/error-shape parity with requireAuth).
pub(crate) enum AuthOutcome {
    Ok(Auth),
    Reject(Response),
}

pub(crate) async fn authenticate(req: &Request, ctx: &RouteContext<()>) -> AuthOutcome {
    let authorization = req
        .headers()
        .get("authorization")
        .ok()
        .flatten()
        .unwrap_or_default();
    let token = auth::bearer_token(&authorization);
    let project_id = ctx.env.var("FIREBASE_PROJECT_ID").ok().map(|v| v.to_string());

    let (Some(token), Some(project_id)) = (token, project_id) else {
        return reject("Authentication required", 401);
    };
    if project_id.is_empty() {
        return reject("Authentication required", 401);
    }

    let keys = match firebase_keys().await {
        Ok(keys) => keys,
        Err(_) => return reject("Authentication unavailable", 503),
    };
    let now = (Date::now().as_millis() / 1000) as i64;
    let Some(identity) = auth::verify_firebase_token(&token, &project_id, now, &keys) else {
        return reject("Authentication failed", 401);
    };

    // Upsert the user, matching requireAuth's INSERT ... ON CONFLICT.
    let db = match ctx.env.d1("DB") {
        Ok(db) => db,
        Err(_) => return reject("Authentication unavailable", 503),
    };
    let now_ms = Date::now().as_millis() as f64;
    let statement = db
        .prepare(
            "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)\n             ON CONFLICT(uid) DO UPDATE SET email = excluded.email, updated_at = excluded.updated_at",
        )
        .bind(&[
            identity.uid.clone().into(),
            match &identity.email {
                Some(email) => email.clone().into(),
                None => JsValue::NULL,
            },
            now_ms.into(),
        ]);
    let statement = match statement {
        Ok(statement) => statement,
        Err(_) => return reject("Authentication unavailable", 503),
    };
    if statement.run().await.is_err() {
        return reject("Authentication unavailable", 503);
    }
    AuthOutcome::Ok(identity)
}

fn reject(message: &str, status: u16) -> AuthOutcome {
    // error_json only fails if JSON serialization of a static shape fails, which
    // cannot happen here; fall back to a plain-text error Response to stay
    // panic-free.
    let response = error_json(message, status)
        .or_else(|_| Response::error(message.to_string(), status))
        .unwrap_or_else(|_| Response::empty().map(|r| r.with_status(status)).unwrap_or_else(|_| Response::error("error", status).expect("error response")));
    AuthOutcome::Reject(response)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

async fn handle_me(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = ctx.env.d1("DB")?;
    let rows = db
        .prepare(
            "SELECT channel, channel_user_id FROM channel_bindings WHERE uid = ?1 AND revoked_at IS NULL",
        )
        .bind(&[auth.uid.clone().into()])?
        .all()
        .await?;
    let channels: Vec<Value> = rows.results::<Value>()?;
    Response::from_json(&json!({
        "uid": auth.uid,
        "email": auth.email,
        "channels": channels,
    }))
}

async fn handle_setup_health(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let AuthOutcome::Reject(response) = authenticate(&req, &ctx).await {
        return Ok(response);
    }
    let get = |name: &str| ctx.env.var(name).ok().map(|v| v.to_string());
    let secret = |name: &str| ctx.env.secret(name).ok().map(|v| v.to_string());
    // vars come from wrangler [vars]; keys come from secrets. Fall back across
    // both so presence is detected regardless of binding kind.
    let any = |name: &str| get(name).or_else(|| secret(name));

    let firebase_project_id = any("FIREBASE_PROJECT_ID");
    let telegram_webhook_secret = any("TELEGRAM_WEBHOOK_SECRET");
    let telegram_bot_token = any("TELEGRAM_BOT_TOKEN");
    let blooio_webhook_signing_secret = any("BLOOIO_WEBHOOK_SIGNING_SECRET");
    let blooio_api_key = any("BLOOIO_API_KEY");
    let stripe_secret_key = any("STRIPE_SECRET_KEY");
    let stripe_pro_price_id = any("STRIPE_PRO_PRICE_ID");
    let stripe_webhook_secret = any("STRIPE_WEBHOOK_SECRET");
    let app_url = any("APP_URL");
    let mimo_api_key = any("MIMO_API_KEY");
    let deepgram_api_key = any("DEEPGRAM_API_KEY");
    let gemini_api_key = any("GEMINI_API_KEY");
    let gemini_live_model = any("GEMINI_LIVE_MODEL");
    let mimo_chat_completions_url = any("MIMO_CHAT_COMPLETIONS_URL");
    let firebase_service_account_email = any("FIREBASE_SERVICE_ACCOUNT_EMAIL");
    let firebase_service_account_private_key = any("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY");

    let body = setup_health_body(&SetupHealthInputs {
        firebase_project_id: firebase_project_id.as_deref(),
        telegram_webhook_secret: telegram_webhook_secret.as_deref(),
        telegram_bot_token: telegram_bot_token.as_deref(),
        blooio_webhook_signing_secret: blooio_webhook_signing_secret.as_deref(),
        blooio_api_key: blooio_api_key.as_deref(),
        stripe_secret_key: stripe_secret_key.as_deref(),
        stripe_pro_price_id: stripe_pro_price_id.as_deref(),
        stripe_webhook_secret: stripe_webhook_secret.as_deref(),
        app_url: app_url.as_deref(),
        mimo_api_key: mimo_api_key.as_deref(),
        deepgram_api_key: deepgram_api_key.as_deref(),
        gemini_api_key: gemini_api_key.as_deref(),
        gemini_live_model: gemini_live_model.as_deref(),
        mimo_chat_completions_url: mimo_chat_completions_url.as_deref(),
        firebase_service_account_email: firebase_service_account_email.as_deref(),
        firebase_service_account_private_key: firebase_service_account_private_key.as_deref(),
    });
    Response::from_json(&body)
}

async fn handle_entitlement(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let pro = has_active_pro(&ctx, &auth.uid).await?;
    Response::from_json(&json!({ "plan": if pro { "pro" } else { "byok" }, "active": pro }))
}

/// Port of entitlement.ts `hasActivePro`: DEV_FAKE_PRO guard then the DB read.
pub(crate) async fn has_active_pro(ctx: &RouteContext<()>, uid: &str) -> Result<bool> {
    let dev = ctx.env.var("DEV_FAKE_PRO").ok().map(|v| v.to_string());
    let environment = ctx.env.var("ENVIRONMENT").ok().map(|v| v.to_string());
    match entitlement::dev_fake_pro(dev.as_deref(), environment.as_deref()) {
        DevFakePro::ForcePro => return Ok(true),
        DevFakePro::IgnoredInProduction => {
            worker::console_warn!(
                "DEV_FAKE_PRO is set but ENVIRONMENT is production; ignoring DEV_FAKE_PRO."
            );
        }
        DevFakePro::NotSet => {}
    }
    let db = ctx.env.d1("DB")?;
    let row = db
        .prepare("SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1")
        .bind(&[uid.into()])?
        .first::<Value>(None)
        .await?;
    let row = match row {
        Some(row) => EntitlementRow {
            plan: row.get("plan").and_then(|v| v.as_str()).map(String::from),
            status: row.get("status").and_then(|v| v.as_str()).map(String::from),
            valid_until: row.get("valid_until").and_then(json_to_i64),
        },
        None => EntitlementRow::default(),
    };
    let now_ms = Date::now().as_millis() as i64;
    Ok(entitlement::row_grants_pro(&row, now_ms))
}

/// D1 returns numbers as JSON numbers, but large integers may arrive as
/// strings; accept either.
pub(crate) fn json_to_i64(value: &Value) -> Option<i64> {
    if value.is_null() {
        return None;
    }
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|f| f as i64))
        .or_else(|| value.as_str().and_then(|s| s.parse::<i64>().ok()))
}

async fn handle_onboarding_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = ctx.env.d1("DB")?;
    let row = db
        .prepare("SELECT onboarding_completed_at FROM users WHERE uid = ?1")
        .bind(&[auth.uid.into()])?
        .first::<Value>(None)
        .await?;
    let completed_at = row
        .as_ref()
        .and_then(|r| r.get("onboarding_completed_at"))
        .and_then(json_to_i64);
    Response::from_json(&json!({
        "complete": completed_at.is_some(),
        "completedAt": completed_at,
    }))
}

async fn handle_onboarding_put(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let body: Option<Value> = req.json().await.ok();
    let complete = body
        .as_ref()
        .and_then(|b| b.get("complete"))
        .and_then(Value::as_bool)
        == Some(true);
    if !complete {
        return error_json("Invalid onboarding state", 400);
    }
    let db = ctx.env.d1("DB")?;
    let now = Date::now().as_millis() as f64;
    db.prepare(
        "INSERT INTO users (uid, email, created_at, updated_at, onboarding_completed_at)\n         VALUES (?1, ?2, ?3, ?3, ?3)\n         ON CONFLICT(uid) DO UPDATE SET\n           onboarding_completed_at = COALESCE(users.onboarding_completed_at, excluded.onboarding_completed_at),\n           updated_at = excluded.updated_at",
    )
    .bind(&[
        auth.uid.clone().into(),
        match &auth.email {
            Some(email) => email.clone().into(),
            None => JsValue::NULL,
        },
        now.into(),
    ])?
    .run()
    .await?;
    let row = db
        .prepare("SELECT onboarding_completed_at FROM users WHERE uid = ?1")
        .bind(&[auth.uid.into()])?
        .first::<Value>(None)
        .await?;
    let completed_at = row
        .as_ref()
        .and_then(|r| r.get("onboarding_completed_at"))
        .and_then(json_to_i64)
        .unwrap_or(now as i64);
    Response::from_json(&json!({ "complete": true, "completedAt": completed_at }))
}

const UID_SCOPED_TABLES: &[&str] = &[
    "pending_embeddings",
    "memory_daily_review_citations",
    "memory_daily_reviews",
    "memory_claim_evidence",
    "memory_profile_entries",
    "memory_claims_fts",
    "memory_claims",
    "memory_evidence",
    "memory_source_revisions",
    "memory_sources",
    "zkr_sync_events",
    "zkr_sync_commits",
    "zkr_memory_records",
    "zkr_memory_projection_state",
    "conversation_replay_cursors",
    "conversation_messages",
    "conversations",
    "channel_inbox_completions",
    "channel_inbox",
    "channel_deliveries",
    "channel_bindings",
    "channel_link_tokens",
    "current_feedback",
    "current_executions",
    "currents",
    "legacy_currents_uncited",
    "managed_ai_requests",
    "managed_stt_sessions",
    "oauth_connections",
    "owner_confirmation_receipts",
    "setting_scopes",
    "user_settings",
    "entitlements",
    "desktop_auth_sessions",
    "audit_events",
    "users",
];

async fn handle_account_delete(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = ctx.env.d1("DB")?;
    // NOTE: the TS handler also enqueues Vectorize deletion of the user's claim
    // vectors via executionCtx.waitUntil. Vectorize has no native workers-rs
    // binding (0.8.5), so that deferred cleanup is intentionally deferred to a
    // later phase — see PORT_STATUS.md. The D1 row deletion below is at full
    // parity.
    let statements: Vec<worker::D1PreparedStatement> = UID_SCOPED_TABLES
        .iter()
        .map(|table| {
            db.prepare(format!("DELETE FROM {table} WHERE uid = ?1"))
                .bind(&[auth.uid.clone().into()])
        })
        .collect::<Result<Vec<_>>>()?;
    db.batch(statements).await?;
    Ok(Response::empty()?.with_status(204))
}

// ===========================================================================
// Phase 2 shared helpers
// ===========================================================================

/// Read a value from `[vars]` first, then from secrets (parity with the
/// setup-health `any()` fallback so presence works regardless of binding kind).
fn secret_or_var(env: &Env, name: &str) -> Option<String> {
    env.var(name)
        .ok()
        .map(|v| v.to_string())
        .or_else(|| env.secret(name).ok().map(|v| v.to_string()))
}

/// Number of rows changed by a run/batch statement (D1 `meta.changes`).
fn changes(result: &worker::D1Result) -> usize {
    result
        .meta()
        .ok()
        .flatten()
        .and_then(|m| m.changes)
        .unwrap_or(0)
}

/// Random UUID v4 (parity with `crypto.randomUUID`). Uses the JS getrandom
/// backend already enabled for wasm.
fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes).expect("getrandom");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let h = crypto_util::to_hex_lower(&bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

fn header(req: &Request, name: &str) -> String {
    req.headers().get(name).ok().flatten().unwrap_or_default()
}

fn now_ms() -> f64 {
    Date::now().as_millis() as f64
}

fn now_seconds() -> i64 {
    (Date::now().as_millis() / 1000) as i64
}

fn js_str(value: &str) -> JsValue {
    value.into()
}

fn js_opt(value: Option<&str>) -> JsValue {
    match value {
        Some(v) => v.into(),
        None => JsValue::NULL,
    }
}

fn row_str(row: &Value, key: &str) -> Option<String> {
    row.get(key).and_then(Value::as_str).map(String::from)
}

// ===========================================================================
// Conversations: appendConversationMessage (shared by webhooks + POST /messages)
// ===========================================================================

struct ConvMessage {
    uid: String,
    client_message_id: String,
    role: String,
    source: String,
    text: String,
    channel_message_id: Option<String>,
    delivery_id: Option<String>,
    created_at: f64,
}

struct AppendedMessage {
    value: Value,
    replayed: bool,
}

/// Port of `appendConversationMessage`. Runs `extra` statements atomically with
/// the conversation + message idempotent inserts, then re-reads the stored row
/// and verifies the payload hash. Returns `None` on hash mismatch (conflict).
async fn append_conversation_message(
    db: &worker::D1Database,
    message: &ConvMessage,
    extra: Vec<worker::D1PreparedStatement>,
) -> Result<Option<AppendedMessage>> {
    let conversation_id = message.uid.clone();
    let now = message.created_at;
    let payload_hash = conv::payload_hash(
        &message.role,
        &message.source,
        &message.text,
        message.channel_message_id.as_deref(),
        message.delivery_id.as_deref(),
    );
    let id = uuid_v4();

    let mut statements = extra;
    statements.push(
        db.prepare(
            "INSERT OR IGNORE INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
        )
        .bind(&[js_str(&conversation_id), now.into()])?,
    );
    statements.push(
        db.prepare(
            "INSERT OR IGNORE INTO conversation_messages\n               (id, conversation_id, uid, client_message_id, role, source, text, payload_hash, channel_message_id, delivery_id, created_at)\n             VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        )
        .bind(&[
            js_str(&id),
            js_str(&conversation_id),
            js_str(&message.client_message_id),
            js_str(&message.role),
            js_str(&message.source),
            js_str(&message.text),
            js_str(&payload_hash),
            js_opt(message.channel_message_id.as_deref()),
            js_opt(message.delivery_id.as_deref()),
            now.into(),
        ])?,
    );
    db.batch(statements).await?;

    let stored = db
        .prepare(
            "SELECT cursor, id, client_message_id, role, source, text, channel_message_id, delivery_id, created_at, payload_hash\n             FROM conversation_messages WHERE conversation_id = ?1 AND client_message_id = ?2 AND uid = ?1",
        )
        .bind(&[js_str(&conversation_id), js_str(&message.client_message_id)])?
        .first::<Value>(None)
        .await?;
    let Some(stored) = stored else {
        return Ok(None);
    };
    if row_str(&stored, "payload_hash").as_deref() != Some(payload_hash.as_str()) {
        return Ok(None);
    }
    let stored_id = row_str(&stored, "id").unwrap_or_default();
    let value = json!({
        "cursor": stored.get("cursor").and_then(json_to_i64),
        "id": stored_id,
        "clientMessageId": row_str(&stored, "client_message_id"),
        "role": row_str(&stored, "role"),
        "source": row_str(&stored, "source"),
        "text": row_str(&stored, "text"),
        "channelMessageId": row_str(&stored, "channel_message_id"),
        "deliveryId": row_str(&stored, "delivery_id"),
        "createdAt": stored.get("created_at").and_then(json_to_i64),
    });
    Ok(Some(AppendedMessage {
        replayed: stored_id != id,
        value,
    }))
}

// ===========================================================================
// Webhooks
// ===========================================================================

/// Insert into webhook_events; returns true when this event is fresh (changes==1).
async fn record_webhook(
    db: &worker::D1Database,
    channel: &str,
    event_id: &str,
) -> Result<bool> {
    let result = db
        .prepare(
            "INSERT OR IGNORE INTO webhook_events (channel, event_id, received_at) VALUES (?1, ?2, ?3)",
        )
        .bind(&[js_str(channel), js_str(event_id), now_ms().into()])?
        .run()
        .await?;
    Ok(changes(&result) == 1)
}

#[derive(PartialEq)]
enum LinkOutcome {
    Linked,
    Invalid,
    Conflict,
}

/// Port of `bind`: consume a link token and bind (or rebind) a channel.
async fn bind_channel(
    db: &worker::D1Database,
    channel: &str,
    channel_user_id: &str,
    channel_chat_id: &str,
    token: &str,
) -> Result<LinkOutcome> {
    let existing = db
        .prepare(
            "SELECT uid FROM channel_bindings WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL",
        )
        .bind(&[js_str(channel), js_str(channel_user_id)])?
        .first::<Value>(None)
        .await?;
    let now = now_ms();
    let token_hash = crypto_util::sha256_hex(token);
    let token_row = db
        .prepare(
            "SELECT uid FROM channel_link_tokens\n             WHERE token_hash = ?1 AND channel = ?2 AND consumed_at IS NULL AND expires_at > ?3",
        )
        .bind(&[js_str(&token_hash), js_str(channel), now.into()])?
        .first::<Value>(None)
        .await?;
    let Some(token_row) = token_row else {
        return Ok(LinkOutcome::Invalid);
    };
    let uid = row_str(&token_row, "uid").unwrap_or_default();
    if let Some(existing) = existing.as_ref() {
        if row_str(existing, "uid").as_deref() != Some(uid.as_str()) {
            return Ok(LinkOutcome::Conflict);
        }
    }
    let details = json!({ "channelUserId": channel_user_id, "channelChatId": channel_chat_id })
        .to_string();
    let results = db
        .batch(vec![
            db.prepare(
                "INSERT INTO channel_bindings (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)\n                 SELECT ?1, ?2, uid, ?3, NULL, ?4 FROM channel_link_tokens\n                 WHERE token_hash = ?5 AND uid = ?6 AND channel = ?1\n                   AND consumed_at IS NULL AND expires_at > ?3\n                 ON CONFLICT(channel, channel_user_id) DO UPDATE SET\n                   uid = excluded.uid, verified_at = excluded.verified_at,\n                   revoked_at = NULL, channel_chat_id = excluded.channel_chat_id",
            )
            .bind(&[
                js_str(channel),
                js_str(channel_user_id),
                now.into(),
                js_str(channel_chat_id),
                js_str(&token_hash),
                js_str(&uid),
            ])?,
            db.prepare(
                "INSERT INTO audit_events\n                   (id, uid, actor_type, action, target_type, target_id, details, created_at)\n                 SELECT ?1, uid, 'channel', 'channel.linked', 'channel', ?2, ?3, ?4\n                 FROM channel_link_tokens\n                 WHERE token_hash = ?5 AND uid = ?6 AND channel = ?2\n                   AND consumed_at IS NULL AND expires_at > ?4",
            )
            .bind(&[
                js_str(&uuid_v4()),
                js_str(channel),
                js_str(&details),
                now.into(),
                js_str(&token_hash),
                js_str(&uid),
            ])?,
            db.prepare(
                "UPDATE channel_link_tokens SET consumed_at = ?1\n                 WHERE token_hash = ?2 AND uid = ?3 AND channel = ?4\n                   AND consumed_at IS NULL AND expires_at > ?1",
            )
            .bind(&[now.into(), js_str(&token_hash), js_str(&uid), js_str(channel)])?,
        ])
        .await?;
    Ok(
        if changes(&results[0]) == 1 && changes(&results[2]) == 1 {
            LinkOutcome::Linked
        } else {
            LinkOutcome::Invalid
        },
    )
}

/// Port of `enqueue`: look up the binding, then append the inbound message with
/// the channel_inbox + audit statements. Returns true when appended.
#[allow(clippy::too_many_arguments)]
async fn enqueue_channel_message(
    db: &worker::D1Database,
    channel: &str,
    event_id: &str,
    message_id: &str,
    channel_user_id: &str,
    channel_chat_id: &str,
    text: &str,
    payload: &Value,
) -> Result<bool> {
    let binding = db
        .prepare(
            "SELECT uid FROM channel_bindings\n             WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL",
        )
        .bind(&[js_str(channel), js_str(channel_user_id)])?
        .first::<Value>(None)
        .await?;
    let Some(binding) = binding else {
        return Ok(false);
    };
    let uid = row_str(&binding, "uid").unwrap_or_default();
    let now = now_ms();
    let event_hash = crypto_util::sha256_hex(&format!("{channel}\u{0}{event_id}"));
    let payload_json = payload.to_string();
    let details = json!({ "channel": channel, "channelChatId": channel_chat_id }).to_string();
    let extra = vec![
        db.prepare(
            "INSERT OR IGNORE INTO channel_inbox\n               (id, uid, channel, event_id, message_id, channel_user_id, channel_chat_id, text, payload, received_at)\n             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        )
        .bind(&[
            js_str(&format!("channel-inbox:{event_hash}")),
            js_str(&uid),
            js_str(channel),
            js_str(event_id),
            js_str(message_id),
            js_str(channel_user_id),
            js_str(channel_chat_id),
            js_str(text),
            js_str(&payload_json),
            now.into(),
        ])?,
        db.prepare(
            "INSERT OR IGNORE INTO audit_events\n               (id, uid, actor_type, action, target_type, target_id, details, created_at)\n             VALUES (?1, ?2, 'channel', 'channel.message_received', 'message', ?3, ?4, ?5)",
        )
        .bind(&[
            js_str(&format!("channel-message:{event_hash}")),
            js_str(&uid),
            js_str(message_id),
            js_str(&details),
            now.into(),
        ])?,
    ];
    let message = ConvMessage {
        uid,
        client_message_id: format!("channel:{channel}:{event_hash}"),
        role: "user".into(),
        source: channel.into(),
        text: text.into(),
        channel_message_id: Some(message_id.into()),
        delivery_id: None,
        created_at: now,
    };
    Ok(append_conversation_message(db, &message, extra).await?.is_some())
}

async fn handle_webhook_telegram(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let secret = secret_or_var(&ctx.env, "TELEGRAM_WEBHOOK_SECRET").unwrap_or_default();
    let supplied = header(&req, "x-telegram-bot-api-secret-token");
    if secret.is_empty()
        || supplied.is_empty()
        || !crypto_util::constant_time_eq(&secret, &supplied)
    {
        return error_json("Unauthorized", 401);
    }
    let body: Option<Value> = req.json().await.ok();
    let body = body.unwrap_or(Value::Null);
    let Ok((event_id, parsed)) = wh::parse_telegram(&body) else {
        return error_json("Invalid update", 400);
    };
    let db = ctx.env.d1("DB")?;
    let fresh = record_webhook(&db, "telegram", &event_id).await?;
    let Some(message) = parsed else {
        return Response::from_json(&json!({ "accepted": true, "queued": false }));
    };
    if let Some(token) = wh::link_token(&message.text, true) {
        if !fresh {
            return Response::from_json(&json!({ "accepted": true, "duplicate": true }));
        }
        let linked = bind_channel(&db, "telegram", &message.user_id, &message.chat_id, &token)
            .await?
            == LinkOutcome::Linked;
        return Response::from_json(&json!({ "accepted": true, "linked": linked }));
    }
    let queued = enqueue_channel_message(
        &db,
        "telegram",
        &event_id,
        &message.message_id,
        &message.user_id,
        &message.chat_id,
        &message.text,
        &body,
    )
    .await?;
    if !fresh {
        return Response::from_json(&json!({ "accepted": true, "duplicate": true }));
    }
    Response::from_json(&json!({ "accepted": queued, "queued": queued }))
}

async fn handle_webhook_blooio(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let secret = secret_or_var(&ctx.env, "BLOOIO_WEBHOOK_SIGNING_SECRET").unwrap_or_default();
    let signature = header(&req, "x-blooio-signature");
    let raw_body = req.text().await?;
    if secret.is_empty()
        || !wh::verify_timestamped_signature(&raw_body, &signature, &secret, now_seconds())
    {
        return error_json("Unauthorized", 401);
    }
    let Ok(body) = serde_json::from_str::<Value>(&raw_body) else {
        return error_json("Invalid body", 400);
    };
    let Some(message) = wh::parse_blooio(&body) else {
        return Response::from_json(&json!({ "accepted": true, "queued": false }));
    };
    let db = ctx.env.d1("DB")?;
    let fresh = record_webhook(&db, "blooio", &message.event_id).await?;
    if let Some(token) = wh::link_token(&message.text, false) {
        if !fresh {
            return Response::from_json(&json!({ "accepted": true, "duplicate": true }));
        }
        let linked = bind_channel(&db, "blooio", &message.sender, &message.chat_id, &token)
            .await?
            == LinkOutcome::Linked;
        return Response::from_json(&json!({ "accepted": true, "linked": linked }));
    }
    let queued = enqueue_channel_message(
        &db,
        "blooio",
        &message.event_id,
        &message.message_id,
        &message.sender,
        &message.chat_id,
        &message.text,
        &body,
    )
    .await?;
    if !fresh {
        return Response::from_json(&json!({ "accepted": true, "duplicate": true }));
    }
    Response::from_json(&json!({ "accepted": queued, "queued": queued }))
}

async fn handle_webhook_stripe(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let secret = secret_or_var(&ctx.env, "STRIPE_WEBHOOK_SECRET").unwrap_or_default();
    let signature = header(&req, "stripe-signature");
    let raw_body = req.text().await?;
    if secret.is_empty()
        || !wh::verify_timestamped_signature(&raw_body, &signature, &secret, now_seconds())
    {
        return error_json("Unauthorized", 401);
    }
    let Ok(event) = serde_json::from_str::<Value>(&raw_body) else {
        return error_json("Invalid body", 400);
    };
    let Ok(envelope) = wh::parse_stripe(&event) else {
        return error_json("Invalid event", 400);
    };
    let db = ctx.env.d1("DB")?;
    let receipt = || {
        db.prepare(
            "INSERT OR IGNORE INTO stripe_events (event_id, event_type, received_at) VALUES (?1, ?2, ?3)",
        )
        .bind(&[
            js_str(&envelope.id),
            js_str(&envelope.event_type),
            now_ms().into(),
        ])
    };
    match &envelope.plan {
        wh::StripePlan::ReceiptOnly { has_object } => {
            let inserted = receipt()?.run().await?;
            let duplicate = changes(&inserted) == 0;
            // Parity: the no-object branch returns just {received, duplicate};
            // an object present but not actionable adds `updated: false`.
            if *has_object {
                Response::from_json(
                    &json!({ "received": true, "duplicate": duplicate, "updated": false }),
                )
            } else {
                Response::from_json(&json!({ "received": true, "duplicate": duplicate }))
            }
        }
        wh::StripePlan::Checkout { uid, customer } => {
            let results = db
                .batch(vec![
                    receipt()?,
                    db.prepare(
                        "INSERT INTO entitlements (uid, plan, status, stripe_customer_id, updated_at)\n                           SELECT uid, 'byok', 'inactive', ?1, ?2 FROM users WHERE uid = ?3\n                           ON CONFLICT(uid) DO UPDATE SET stripe_customer_id = excluded.stripe_customer_id,\n                             updated_at = excluded.updated_at",
                    )
                    .bind(&[js_str(customer), now_ms().into(), js_str(uid)])?,
                ])
                .await?;
            Response::from_json(&json!({
                "received": true,
                "duplicate": changes(&results[0]) == 0,
                "updated": changes(&results[1]) == 1,
            }))
        }
        wh::StripePlan::Subscription(sub) => {
            let results = db
                .batch(vec![
                    receipt()?,
                    db.prepare(
                        "INSERT INTO entitlements\n                           (uid, plan, status, valid_until, stripe_customer_id, updated_at, stripe_subscription_id, stripe_price_id, stripe_event_created)\n                         SELECT uid, 'pro', ?1, ?2, ?3, ?4, ?5, ?6, ?7 FROM users WHERE uid = ?8\n                         ON CONFLICT(uid) DO UPDATE SET\n                           plan = 'pro', status = excluded.status, valid_until = excluded.valid_until,\n                           stripe_customer_id = excluded.stripe_customer_id,\n                           stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, entitlements.stripe_subscription_id),\n                           stripe_price_id = COALESCE(excluded.stripe_price_id, entitlements.stripe_price_id),\n                           stripe_event_created = excluded.stripe_event_created,\n                           updated_at = excluded.updated_at\n                         WHERE excluded.stripe_event_created >= entitlements.stripe_event_created",
                    )
                    .bind(&[
                        js_str(if sub.active { "active" } else { "inactive" }),
                        match sub.valid_until {
                            Some(v) => (v as f64).into(),
                            None => JsValue::NULL,
                        },
                        js_str(&sub.customer),
                        now_ms().into(),
                        js_opt(sub.subscription.as_deref()),
                        js_opt(sub.price_id.as_deref()),
                        (sub.event_created as f64).into(),
                        js_str(&sub.uid),
                    ])?,
                ])
                .await?;
            Response::from_json(&json!({
                "received": true,
                "duplicate": changes(&results[0]) == 0,
                "updated": changes(&results[1]) == 1,
            }))
        }
    }
}

// ===========================================================================
// Desktop auth
// ===========================================================================

/// Parse a JSON object body, returning `None` for non-objects (parity with the
/// desktop-auth `json` helper).
async fn json_object(req: &mut Request) -> Option<Value> {
    let value: Value = req.json().await.ok()?;
    if value.is_object() {
        Some(value)
    } else {
        None
    }
}

fn session_value(body: &Option<Value>, key: &str) -> Option<String> {
    let raw = body.as_ref()?.get(key)?.as_str()?;
    if desktop_auth::valid_session_value(raw) {
        Some(raw.to_string())
    } else {
        None
    }
}

async fn handle_desktop_start(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = json_object(&mut req).await;
    let session_id = session_value(&body, "sessionId");
    let challenge = session_value(&body, "challenge");
    let confirmation_challenge = session_value(&body, "confirmationChallenge");
    let app_url = secret_or_var(&ctx.env, "APP_URL");
    let (Some(session_id), Some(challenge), Some(confirmation_challenge)) =
        (session_id, challenge, confirmation_challenge)
    else {
        return error_json("Invalid handoff", 400);
    };
    let app_origin = app_url
        .as_deref()
        .and_then(desktop_auth::valid_public_origin);
    let Some(app_origin) = app_origin else {
        return error_json("Desktop handoff unavailable", 503);
    };
    let now = now_ms();
    let client_ip = {
        let ip = header(&req, "cf-connecting-ip");
        if ip.is_empty() {
            "unknown".to_string()
        } else {
            ip
        }
    };
    let db = ctx.env.d1("DB")?;
    db.prepare(
        "DELETE FROM desktop_auth_sessions WHERE expires_at <= ?1 OR consumed_at IS NOT NULL",
    )
    .bind(&[now.into()])?
    .run()
    .await?;
    let recent = db
        .prepare(
            "SELECT COUNT(*) AS count FROM desktop_auth_sessions WHERE client_ip = ?1 AND created_at > ?2",
        )
        .bind(&[js_str(&client_ip), (now - 10.0 * 60.0 * 1000.0).into()])?
        .first::<Value>(None)
        .await?;
    let count = recent
        .as_ref()
        .and_then(|r| r.get("count"))
        .and_then(json_to_i64)
        .unwrap_or(0);
    if count >= 10 {
        return error_json("Too many handoffs", 429);
    }
    let inserted = db
        .prepare(
            "INSERT INTO desktop_auth_sessions (id, verifier_challenge, confirmation_challenge, client_ip, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(&[
            js_str(&session_id),
            js_str(&challenge),
            js_str(&confirmation_challenge),
            js_str(&client_ip),
            now.into(),
            (now + desktop_auth::LIFETIME_MS as f64).into(),
        ])?
        .run()
        .await;
    if inserted.is_err() {
        return error_json("Handoff already exists", 409);
    }
    // Build browserUrl: <appOrigin>/?desktop_auth=<sessionId>
    let mut browser = Url::parse(&app_origin).map_err(|e| worker::Error::RustError(e.to_string()))?;
    browser.set_path("/");
    browser
        .query_pairs_mut()
        .append_pair("desktop_auth", &session_id);
    Ok(Response::from_json(&json!({
        "browserUrl": browser.to_string(),
        "expiresAt": now as i64 + desktop_auth::LIFETIME_MS,
    }))?
    .with_status(201))
}

/// Port of `bindDesktopSession`: the atomic confirmation-code check with
/// attempt counting and lockout.
async fn bind_desktop_session(
    db: &worker::D1Database,
    session_id: &str,
    uid: &str,
    confirmation_code: &str,
    now: f64,
) -> Result<bool> {
    let confirmation = desktop_auth::verifier_challenge(confirmation_code);
    let row = db
        .prepare(
            "UPDATE desktop_auth_sessions\n             SET uid = CASE WHEN confirmation_challenge = ?3 THEN ?1 ELSE uid END,\n                 confirmation_attempts = confirmation_attempts + CASE WHEN confirmation_challenge = ?3 THEN 0 ELSE 1 END,\n                 confirmation_locked_at = CASE\n                   WHEN confirmation_challenge != ?3 AND confirmation_attempts + 1 >= 5 THEN ?4\n                   ELSE confirmation_locked_at\n                 END\n             WHERE id = ?2 AND uid IS NULL AND consumed_at IS NULL AND expires_at > ?4\n               AND confirmation_locked_at IS NULL AND confirmation_attempts < 5\n             RETURNING uid, confirmation_attempts, confirmation_locked_at",
        )
        .bind(&[
            js_str(uid),
            js_str(session_id),
            js_str(&confirmation),
            now.into(),
        ])?
        .first::<Value>(None)
        .await?;
    Ok(row.and_then(|r| row_str(&r, "uid")).as_deref() == Some(uid))
}

async fn handle_desktop_complete(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = json_object(&mut req).await;
    let session_id = session_value(&body, "sessionId");
    let confirmation_code = body
        .as_ref()
        .and_then(|b| b.get("confirmationCode"))
        .and_then(Value::as_str)
        .filter(|c| desktop_auth::valid_confirmation_code(c))
        .map(String::from);
    let project_id = secret_or_var(&ctx.env, "FIREBASE_PROJECT_ID");
    let authorization = header(&req, "authorization");
    let (Some(session_id), Some(confirmation_code), Some(project_id)) =
        (session_id, confirmation_code, project_id)
    else {
        return error_json("Authentication required", 401);
    };
    if project_id.is_empty() || !authorization.starts_with("Bearer ") {
        return error_json("Authentication required", 401);
    }
    let token = authorization[7..].trim().to_string();
    let keys = match firebase_keys().await {
        Ok(keys) => keys,
        Err(_) => return error_json("Authentication service unavailable", 503),
    };
    let Some(auth) = auth::verify_firebase_token(&token, &project_id, now_seconds(), &keys) else {
        return error_json("Authentication failed", 401);
    };
    let db = ctx.env.d1("DB")?;
    let now = now_ms();
    db.prepare(
        "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)\n         ON CONFLICT(uid) DO UPDATE SET email = excluded.email, updated_at = excluded.updated_at",
    )
    .bind(&[
        js_str(&auth.uid),
        js_opt(auth.email.as_deref()),
        now.into(),
    ])?
    .run()
    .await?;
    if !bind_desktop_session(&db, &session_id, &auth.uid, &confirmation_code, now).await? {
        return error_json("Handoff expired or already completed", 409);
    }
    Response::from_json(&json!({ "completed": true }))
}

async fn handle_desktop_exchange(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = json_object(&mut req).await;
    let session_id = session_value(&body, "sessionId");
    let verifier = session_value(&body, "verifier");
    let email = secret_or_var(&ctx.env, "FIREBASE_SERVICE_ACCOUNT_EMAIL");
    let private_key = secret_or_var(&ctx.env, "FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY");
    let (Some(session_id), Some(verifier)) = (session_id, verifier) else {
        return error_json("Invalid handoff", 400);
    };
    let (Some(email), Some(private_key)) = (email, private_key) else {
        return error_json("Desktop token signing unavailable", 503);
    };
    let challenge = desktop_auth::verifier_challenge(&verifier);
    let now = now_ms();
    let db = ctx.env.d1("DB")?;
    let row = db
        .prepare(
            "SELECT uid FROM desktop_auth_sessions WHERE id = ?1 AND verifier_challenge = ?2 AND consumed_at IS NULL AND expires_at > ?3",
        )
        .bind(&[js_str(&session_id), js_str(&challenge), now.into()])?
        .first::<Value>(None)
        .await?;
    let Some(row) = row else {
        return error_json("Handoff expired", 410);
    };
    let uid = row_str(&row, "uid");
    let Some(uid) = uid else {
        return Ok(Response::from_json(&json!({ "status": "pending" }))?.with_status(409));
    };
    let Some(token) =
        desktop_auth::create_firebase_custom_token(&uid, &email, &private_key, now_seconds())
    else {
        return error_json("Desktop token signing unavailable", 503);
    };
    let consumed = db
        .prepare(
            "UPDATE desktop_auth_sessions SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
        )
        .bind(&[now.into(), js_str(&session_id)])?
        .run()
        .await?;
    if changes(&consumed) != 1 {
        return error_json("Handoff already consumed", 409);
    }
    Response::from_json(&json!({ "customToken": token }))
}

// ===========================================================================
// Billing
// ===========================================================================

/// POST to the Stripe API and validate the JSON session response.
async fn stripe_request(
    secret: &str,
    path: &str,
    params: &[(String, String)],
) -> Result<Option<(String, String)>> {
    let url = Url::parse(&format!("https://api.stripe.com/v1/{path}"))
        .map_err(|e| worker::Error::RustError(e.to_string()))?;
    let headers = worker::Headers::new();
    headers.set("authorization", &format!("Bearer {secret}"))?;
    headers.set("content-type", "application/x-www-form-urlencoded")?;
    headers.set("stripe-version", "2026-02-25.clover")?;
    let mut init = worker::RequestInit::new();
    init.with_method(worker::Method::Post)
        .with_headers(headers)
        .with_body(Some(JsValue::from_str(&billing::encode_form(params))));
    let request = Request::new_with_init(url.as_str(), &init)?;
    let mut response = Fetch::Request(request).send().await?;
    let ok = (200..300).contains(&response.status_code());
    let body: Value = response.json().await.unwrap_or(Value::Null);
    Ok(billing::parse_session(ok, &body))
}

async fn handle_billing_checkout(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let secret = secret_or_var(&ctx.env, "STRIPE_SECRET_KEY");
    let price_id = secret_or_var(&ctx.env, "STRIPE_PRO_PRICE_ID");
    let app_url = secret_or_var(&ctx.env, "APP_URL");
    let (Some(secret), Some(price_id), Some(app_url)) = (secret, price_id, app_url) else {
        return error_json("Billing unavailable", 503);
    };
    let db = ctx.env.d1("DB")?;
    let entitlement = db
        .prepare("SELECT stripe_customer_id FROM entitlements WHERE uid = ?1")
        .bind(&[js_str(&auth.uid)])?
        .first::<Value>(None)
        .await?;
    let customer_id = entitlement
        .as_ref()
        .and_then(|r| row_str(r, "stripe_customer_id"));
    let params = billing::checkout_params(
        &auth.uid,
        &price_id,
        &app_url,
        customer_id.as_deref(),
        auth.email.as_deref(),
    );
    match stripe_request(&secret, "checkout/sessions", &params).await? {
        Some((id, url)) => {
            Ok(Response::from_json(&json!({ "id": id, "url": url }))?.with_status(201))
        }
        None => error_json("Billing provider unavailable", 502),
    }
}

async fn handle_billing_portal(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let secret = secret_or_var(&ctx.env, "STRIPE_SECRET_KEY");
    let app_url = secret_or_var(&ctx.env, "APP_URL");
    let (Some(secret), Some(app_url)) = (secret, app_url) else {
        return error_json("Billing unavailable", 503);
    };
    let db = ctx.env.d1("DB")?;
    let entitlement = db
        .prepare("SELECT stripe_customer_id FROM entitlements WHERE uid = ?1")
        .bind(&[js_str(&auth.uid)])?
        .first::<Value>(None)
        .await?;
    let customer_id = entitlement
        .as_ref()
        .and_then(|r| row_str(r, "stripe_customer_id"));
    let Some(customer_id) = customer_id else {
        return error_json("Billing account not found", 404);
    };
    let params = billing::portal_params(&customer_id, &app_url);
    match stripe_request(&secret, "billing_portal/sessions", &params).await? {
        Some((id, url)) => {
            Ok(Response::from_json(&json!({ "id": id, "url": url }))?.with_status(201))
        }
        None => error_json("Billing provider unavailable", 502),
    }
}

// ===========================================================================
// Conversations
// ===========================================================================

const LEASE_MS: f64 = 5.0 * 60_000.0;

async fn handle_inbox_claim(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = ctx.env.d1("DB")?;
    let now = now_ms();
    db.prepare(
        "UPDATE channel_inbox SET status = 'failed', lease_until = NULL, lease_token = NULL,\n           last_error = 'Automatic retry limit reached', completed_at = ?2\n         WHERE uid = ?1 AND status = 'processing' AND lease_until <= ?2\n           AND attempts >= 5",
    )
    .bind(&[js_str(&auth.uid), now.into()])?
    .run()
    .await?;
    let lease_token = uuid_v4();
    let item = db
        .prepare(
            "UPDATE channel_inbox\n             SET status = 'processing', attempts = attempts + 1, lease_until = ?2,\n                 lease_token = ?3, last_error = NULL\n             WHERE uid = ?1\n               AND id = (\n                 SELECT id FROM channel_inbox\n                 WHERE uid = ?1 AND status IN ('pending', 'processing')\n                 ORDER BY received_at, id LIMIT 1\n               )\n               AND attempts < 5\n               AND (status = 'pending' OR (\n                 status = 'processing' AND lease_until <= ?4\n               ))\n             RETURNING id, channel, message_id, text, received_at, attempts, lease_token, lease_until",
        )
        .bind(&[
            js_str(&auth.uid),
            (now + LEASE_MS).into(),
            js_str(&lease_token),
            now.into(),
        ])?
        .first::<Value>(None)
        .await?;
    let item_json = match item {
        Some(item) => {
            let text = row_str(&item, "text").unwrap_or_default();
            let memory_context = memory_context_for(&ctx.env, &auth.uid, &text).await;
            json!({
                "id": row_str(&item, "id"),
                "channel": row_str(&item, "channel"),
                "text": text,
                "channelMessageId": row_str(&item, "message_id"),
                "receivedAt": item.get("received_at").and_then(json_to_i64),
                "attempt": item.get("attempts").and_then(json_to_i64),
                "leaseToken": row_str(&item, "lease_token"),
                "leaseUntil": item.get("lease_until").and_then(json_to_i64),
                "memoryContext": memory_context,
            })
        }
        None => Value::Null,
    };
    Response::from_json(&json!({ "item": item_json }))
}

/// Server-retrieved memory context for an inbox item.
///
/// Delegates to the canonical `routes_memory::memory_context_for` (the single
/// Vectorize FFI + Workers AI embeddings implementation). Returns `null` when
/// `MEMORY_VECTORS`/`AI` are unbound or the search yields nothing — parity-safe
/// with the TS `memoryContextFor` graceful fallback. See PORT_STATUS.md.
async fn memory_context_for(env: &Env, uid: &str, query: &str) -> Value {
    match crate::routes_memory::memory_context_for(env, uid, query).await {
        Some(text) => Value::String(text),
        None => Value::Null,
    }
}

async fn handle_inbox_complete(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let body: Value = req.json().await.unwrap_or(Value::Null);
    let Some(outcome) = conv::validate_inbox_complete(&body) else {
        return error_json("Invalid inbox outcome", 400);
    };
    let now = now_ms();
    let id = ctx.param("id").cloned().unwrap_or_default();
    let db = ctx.env.d1("DB")?;
    match outcome {
        conv::InboxOutcome::Done { lease_token, reply } => {
            match complete_inbox_done(&ctx.env, &db, &auth.uid, &id, &lease_token, &reply, now)
                .await?
            {
                Ok(delivery) => {
                    Response::from_json(&json!({ "status": "done", "delivery": delivery }))
                }
                Err(message) => Ok(Response::from_json(&json!({ "error": message }))?
                    .with_status(409)),
            }
        }
        conv::InboxOutcome::Retry { lease_token, error } => {
            db.batch(vec![
                db.prepare(
                    "UPDATE channel_inbox SET\n                     status = CASE\n                       WHEN attempts < 5 THEN 'pending'\n                       ELSE 'failed'\n                     END,\n                     lease_until = NULL, last_error = ?1,\n                     completed_at = CASE\n                       WHEN attempts >= 5 THEN ?2 ELSE NULL\n                     END\n                   WHERE id = ?3 AND uid = ?4 AND status = 'processing'\n                     AND lease_token = ?5 AND lease_until > ?2\n                   RETURNING status",
                )
                .bind(&[
                    js_opt(error.as_deref()),
                    now.into(),
                    js_str(&id),
                    js_str(&auth.uid),
                    js_str(&lease_token),
                ])?,
                db.prepare(
                    "INSERT OR IGNORE INTO channel_inbox_completions\n                       (inbox_id, uid, attempt, lease_token, outcome, result_status, completed_at)\n                     SELECT id, uid, attempts, ?1, 'retry', status, ?2\n                     FROM channel_inbox\n                     WHERE id = ?3 AND uid = ?4 AND lease_token = ?1\n                       AND status IN ('pending', 'failed')",
                )
                .bind(&[js_str(&lease_token), now.into(), js_str(&id), js_str(&auth.uid)])?,
            ])
            .await?;
            let replay = db
                .prepare(
                    "SELECT result_status FROM channel_inbox_completions\n                     WHERE inbox_id = ?1 AND uid = ?2 AND lease_token = ?3 AND outcome = 'retry'",
                )
                .bind(&[js_str(&id), js_str(&auth.uid), js_str(&lease_token)])?
                .first::<Value>(None)
                .await?;
            match replay.and_then(|r| row_str(&r, "result_status")) {
                Some(status) => Response::from_json(&json!({ "status": status })),
                None => Ok(Response::from_json(&json!({ "error": "Inbox lease conflict" }))?
                    .with_status(409)),
            }
        }
    }
}

/// Port of `completeInboxItemDone`. Returns Ok(delivery) or Err(message).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn complete_inbox_done(
    _env: &Env,
    db: &worker::D1Database,
    uid: &str,
    id: &str,
    lease_token: &str,
    reply: &str,
    now: f64,
) -> Result<std::result::Result<Value, String>> {
    let inbox = db
        .prepare(
            "SELECT i.channel, i.attempts, i.status, d.id AS delivery_id,\n                    d.state AS delivery_state, d.attempts AS delivery_attempts,\n                    d.provider_message_id, d.last_error, d.text AS delivery_text\n             FROM channel_inbox i\n             LEFT JOIN channel_deliveries d\n               ON d.uid = i.uid AND d.channel = i.channel\n              AND d.idempotency_key = 'inbox:' || i.id || ':attempt:' || i.attempts\n             WHERE i.id = ?1 AND i.uid = ?2 AND i.lease_token = ?3\n               AND (i.status = 'done' OR (\n                 i.status = 'processing' AND i.lease_until > ?4\n               ))",
        )
        .bind(&[js_str(id), js_str(uid), js_str(lease_token), now.into()])?
        .first::<Value>(None)
        .await?;
    let Some(inbox) = inbox else {
        return Ok(Err("Inbox lease conflict".into()));
    };
    let channel = row_str(&inbox, "channel").unwrap_or_default();
    let status = row_str(&inbox, "status").unwrap_or_default();
    let attempts = inbox.get("attempts").and_then(json_to_i64).unwrap_or(0);

    if status == "done" {
        let delivery_id = row_str(&inbox, "delivery_id");
        let delivery_text = row_str(&inbox, "delivery_text");
        if delivery_id.is_none() || delivery_text.as_deref() != Some(reply) {
            return Ok(Err("Inbox completion conflict".into()));
        }
        return Ok(Ok(json!({
            "id": delivery_id,
            "state": row_str(&inbox, "delivery_state"),
            "attempts": inbox.get("delivery_attempts").and_then(json_to_i64),
            "provider_message_id": row_str(&inbox, "provider_message_id"),
            "last_error": row_str(&inbox, "last_error"),
        })));
    }

    let client_message_id = format!("inbox-reply:{id}:{attempts}");
    let idempotency_key = format!("inbox:{id}:attempt:{attempts}");
    let delivery_id = format!("inbox-delivery:{id}:{attempts}");
    let payload_hash = conv::payload_hash("assistant", &channel, reply, None, Some(&delivery_id));

    let results = db
        .batch(vec![
            db.prepare(
                "INSERT OR IGNORE INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
            )
            .bind(&[js_str(uid), now.into()])?,
            db.prepare(
                "INSERT OR IGNORE INTO channel_deliveries\n                     (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at)\n                   SELECT ?1, i.uid, i.channel, ?2, i.channel_chat_id, ?3, ?4, ?4, ?4\n                   FROM channel_inbox i\n                   WHERE i.id = ?5 AND i.uid = ?6 AND i.status = 'processing'\n                     AND i.lease_token = ?7 AND i.lease_until > ?4\n                     AND EXISTS (\n                       SELECT 1 FROM channel_bindings b\n                       WHERE b.uid = i.uid AND b.channel = i.channel\n                         AND b.revoked_at IS NULL\n                         AND COALESCE(b.channel_chat_id, b.channel_user_id) = i.channel_chat_id\n                     )",
            )
            .bind(&[
                js_str(&delivery_id),
                js_str(&idempotency_key),
                js_str(reply),
                now.into(),
                js_str(id),
                js_str(uid),
                js_str(lease_token),
            ])?,
            db.prepare(
                "INSERT OR IGNORE INTO conversation_messages\n                     (id, conversation_id, uid, client_message_id, role, source, text, payload_hash, channel_message_id, delivery_id, created_at)\n                   SELECT ?1, i.uid, i.uid, ?2, 'assistant', i.channel, ?3, ?4, NULL, ?5, ?6\n                   FROM channel_inbox i\n                   JOIN channel_deliveries d ON d.id = ?5 AND d.uid = i.uid\n                   WHERE i.id = ?7 AND i.uid = ?8 AND i.status = 'processing'\n                     AND i.lease_token = ?9 AND i.lease_until > ?6",
            )
            .bind(&[
                js_str(&client_message_id),
                js_str(&client_message_id),
                js_str(reply),
                js_str(&payload_hash),
                js_str(&delivery_id),
                now.into(),
                js_str(id),
                js_str(uid),
                js_str(lease_token),
            ])?,
            db.prepare(
                "UPDATE channel_inbox\n                     SET status = 'done', lease_until = NULL,\n                         last_error = NULL, completed_at = ?1\n                     WHERE id = ?2 AND uid = ?3 AND status = 'processing'\n                       AND lease_token = ?4 AND lease_until > ?1\n                       AND EXISTS (SELECT 1 FROM channel_deliveries WHERE id = ?5 AND uid = ?3)",
            )
            .bind(&[
                now.into(),
                js_str(id),
                js_str(uid),
                js_str(lease_token),
                js_str(&delivery_id),
            ])?,
        ])
        .await?;

    if changes(&results[1]) != 1 || changes(&results[2]) != 1 || changes(&results[3]) != 1 {
        let persisted = db
            .prepare(
                "SELECT i.status, d.text\n                 FROM channel_inbox i\n                 JOIN channel_deliveries d ON d.id = ?1 AND d.uid = i.uid\n                 WHERE i.id = ?2 AND i.uid = ?3 AND i.lease_token = ?4",
            )
            .bind(&[js_str(&delivery_id), js_str(id), js_str(uid), js_str(lease_token)])?
            .first::<Value>(None)
            .await?;
        let ok = persisted
            .as_ref()
            .map(|p| {
                row_str(p, "status").as_deref() == Some("done")
                    && row_str(p, "text").as_deref() == Some(reply)
            })
            .unwrap_or(false);
        if !ok {
            return Ok(Err("Channel is not linked".into()));
        }
    }

    // NOTE: the TS handler best-effort calls dispatchChannelMessage (the
    // DeliveryCoordinator DO) inside a try/catch that ignores failures. The DO
    // port is a later phase; skipping it here matches the ignore-on-error
    // semantics (the scheduled `deliverDueChannelMessages` also drains
    // deliveries). See PORT_STATUS.md.

    let delivery = db
        .prepare(
            "SELECT id, state, attempts, provider_message_id, last_error FROM channel_deliveries WHERE id = ?1 AND uid = ?2",
        )
        .bind(&[js_str(&delivery_id), js_str(uid)])?
        .first::<Value>(None)
        .await?;
    Ok(Ok(delivery.unwrap_or(Value::Null)))
}

async fn handle_messages_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let url = req.url()?;
    let mut after: i64 = 0;
    let mut limit: i64 = 100;
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "after" => after = value.parse().unwrap_or(i64::MIN),
            "limit" => limit = value.parse().unwrap_or(i64::MIN),
            _ => {}
        }
    }
    if !conv::validate_replay_range(after, limit) {
        return error_json("Invalid replay range", 400);
    }
    let db = ctx.env.d1("DB")?;
    let rows = db
        .prepare(
            "SELECT cursor, id, client_message_id, role, source, text, channel_message_id, delivery_id, created_at\n             FROM conversation_messages\n             WHERE uid = ?1 AND conversation_id = ?1 AND cursor > ?2\n             ORDER BY cursor LIMIT ?3",
        )
        .bind(&[js_str(&auth.uid), (after as f64).into(), (limit as f64).into()])?
        .all()
        .await?;
    let raw: Vec<Value> = rows.results::<Value>()?;
    let messages: Vec<Value> = raw
        .iter()
        .map(|row| {
            json!({
                "cursor": row.get("cursor").and_then(json_to_i64),
                "id": row_str(row, "id"),
                "clientMessageId": row_str(row, "client_message_id"),
                "role": row_str(row, "role"),
                "source": row_str(row, "source"),
                "text": row_str(row, "text"),
                "channelMessageId": row_str(row, "channel_message_id"),
                "deliveryId": row_str(row, "delivery_id"),
                "createdAt": row.get("created_at").and_then(json_to_i64),
            })
        })
        .collect();
    let next_cursor = messages
        .last()
        .and_then(|m| m.get("cursor").and_then(json_to_i64))
        .unwrap_or(after);
    Response::from_json(&json!({
        "conversationId": "default",
        "messages": messages,
        "nextCursor": next_cursor,
    }))
}

async fn handle_messages_post(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let body: Value = req.json().await.unwrap_or(Value::Null);
    let get = |key: &str| body.get(key).cloned().unwrap_or(Value::Null);
    let Some(input) = conv::validate_append(&get("clientMessageId"), &get("role"), &get("source"), &get("text"))
    else {
        return error_json("Invalid conversation message", 400);
    };
    let db = ctx.env.d1("DB")?;
    let message = ConvMessage {
        uid: auth.uid.clone(),
        client_message_id: input.client_message_id,
        role: input.role,
        source: input.source,
        text: input.text,
        channel_message_id: None,
        delivery_id: None,
        created_at: now_ms(),
    };
    match append_conversation_message(&db, &message, Vec::new()).await? {
        Some(appended) => {
            let status = if appended.replayed { 200 } else { 201 };
            Ok(Response::from_json(&json!({
                "conversationId": "default",
                "message": appended.value,
            }))?
            .with_status(status))
        }
        None => Ok(Response::from_json(&json!({ "error": "Client message ID conflict" }))?
            .with_status(409)),
    }
}

async fn handle_cursor_put(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let client_id = ctx.param("clientId").cloned().unwrap_or_default();
    let body: Value = req.json().await.unwrap_or(Value::Null);
    let cursor = body.get("cursor").and_then(json_to_i64);
    let expected_revision = body.get("expectedRevision").and_then(json_to_i64);
    let (Some(cursor), Some(expected_revision)) = (cursor, expected_revision) else {
        return error_json("Invalid replay cursor", 400);
    };
    if !conv::valid_cursor_client_id(&client_id)
        || cursor < 0
        || expected_revision < 0
        || cursor > 9_007_199_254_740_991
        || expected_revision > 9_007_199_254_740_991
    {
        return error_json("Invalid replay cursor", 400);
    }
    let db = ctx.env.d1("DB")?;
    let now = now_ms();
    db.prepare(
        "INSERT INTO conversations (id, uid, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)\n         ON CONFLICT(uid) DO NOTHING",
    )
    .bind(&[js_str(&auth.uid), now.into()])?
    .run()
    .await?;
    let result = if expected_revision == 0 {
        db.prepare(
            "INSERT OR IGNORE INTO conversation_replay_cursors\n               (uid, conversation_id, client_id, cursor, revision, updated_at)\n             VALUES (?1, ?1, ?2, ?3, 1, ?4)",
        )
        .bind(&[
            js_str(&auth.uid),
            js_str(&client_id),
            (cursor as f64).into(),
            now.into(),
        ])?
        .run()
        .await?
    } else {
        db.prepare(
            "UPDATE conversation_replay_cursors\n             SET cursor = ?1, revision = revision + 1, updated_at = ?2\n             WHERE uid = ?3 AND conversation_id = ?3 AND client_id = ?4\n               AND revision = ?5 AND cursor <= ?1",
        )
        .bind(&[
            (cursor as f64).into(),
            now.into(),
            js_str(&auth.uid),
            js_str(&client_id),
            (expected_revision as f64).into(),
        ])?
        .run()
        .await?
    };
    if changes(&result) != 1 {
        return Ok(Response::from_json(&json!({ "error": "Replay cursor conflict" }))?
            .with_status(409));
    }
    let stored = db
        .prepare(
            "SELECT cursor, revision, updated_at FROM conversation_replay_cursors WHERE uid = ?1 AND conversation_id = ?1 AND client_id = ?2",
        )
        .bind(&[js_str(&auth.uid), js_str(&client_id)])?
        .first::<Value>(None)
        .await?;
    let stored = stored.unwrap_or(Value::Null);
    Response::from_json(&json!({
        "cursor": stored.get("cursor").and_then(json_to_i64),
        "revision": stored.get("revision").and_then(json_to_i64),
        "updatedAt": stored.get("updated_at").and_then(json_to_i64),
    }))
}
