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
        .delete_async("/v1/account", handle_account_delete);
    crate::routes_ai::register(router)
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
fn json_to_i64(value: &Value) -> Option<i64> {
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
