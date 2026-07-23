//! workers-rs glue for the delivery & OAuth group. Compiled only for wasm32.
//!
//! Behaviour parity with `worker/src/delivery.ts`, `worker/src/inbox-fallback.ts`,
//! `worker/src/oauth-broker.ts`, and `worker/src/oauth-proxy.ts`. The pure
//! decision logic lives in `crate::delivery`, `crate::oauth`, and
//! `crate::inbox_fallback`; this file is the thin I/O layer (Durable Object,
//! D1, provider `fetch`, discovery cache, refresh lock) that drives them.
//!
//! Routes are added to the shared Router through [`register`] (called from the
//! single merge seam in `glue.rs`). The `DeliveryCoordinator` Durable Object and
//! the scheduled delivery tick are additive; see the MERGE notes.

use std::cell::RefCell;

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::*;

use crate::delivery::{
    self, coordinator_name, http_outcome, network_error_message, network_outcome, retry_delay,
    stable_idempotency_key, Channel, RetryAfterHints, MAX_ATTEMPTS,
};
use crate::glue::{authenticate, error_json, AuthOutcome};
use crate::inbox_fallback as fallback;
use crate::oauth::{
    classify_poll_error, connection_expires_at, decrypt_oauth_token, encrypt_oauth_token,
    import_oauth_token_key, needs_refresh, openai_config, refreshed_expires_at, valid_account_id,
    valid_xai_endpoint, xai_config, PollOutcome, ProviderConfig, OPENAI_UPSTREAM, XAI_UPSTREAM,
};
use crate::rate_limit_lock::{acquire_refresh_lock, consume_rate_limit, release_refresh_lock};
use crate::worker_util::{now_ms, uuid_v4 as random_uuid};

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

/// A random jitter draw in `[0, 1)` for the backoff computation.
fn random_jitter() -> f64 {
    let mut bytes = [0u8; 8];
    getrandom::getrandom(&mut bytes).expect("getrandom");
    (u64::from_le_bytes(bytes) as f64) / (u64::MAX as f64 + 1.0)
}

/// `application/x-www-form-urlencoded` body (parity with `URLSearchParams`).
fn form_encode(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            b' ' => out.push('+'),
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

fn json_str(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(String::from)
}

fn json_i64(value: &Value, key: &str) -> Option<i64> {
    value
        .get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// Build a POST request with a form body.
fn form_post(url: &str, body: &str) -> Result<Request> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/x-www-form-urlencoded")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(body)));
    Request::new_with_init(url, &init)
}

// ===========================================================================
// delivery.ts — DeliveryCoordinator Durable Object + cron dispatch
// ===========================================================================

struct DeliveryRow {
    id: String,
    uid: String,
    channel: Channel,
    channel_chat_id: String,
    text: String,
    attempts: u32,
    idempotency_key: String,
    lease_token: String,
}

fn row_to_delivery(row: &Value) -> Option<DeliveryRow> {
    Some(DeliveryRow {
        id: json_str(row, "id")?,
        uid: json_str(row, "uid")?,
        channel: Channel::parse(&json_str(row, "channel")?)?,
        channel_chat_id: json_str(row, "channel_chat_id")?,
        text: json_str(row, "text")?,
        attempts: json_i64(row, "attempts").unwrap_or(0) as u32,
        idempotency_key: json_str(row, "idempotency_key").unwrap_or_default(),
        lease_token: json_str(row, "lease_token")?,
    })
}

const CLAIM_SQL: &str = "UPDATE channel_deliveries\n       SET state = 'delivering', attempts = attempts + 1, lease_until = ?2, lease_token = ?5, updated_at = ?1\n       WHERE id = ?3 AND uid = ?6 AND channel = ?7 AND attempts < ?4\n         AND EXISTS (\n           SELECT 1 FROM channel_bindings b\n           WHERE b.uid = channel_deliveries.uid AND b.channel = channel_deliveries.channel\n             AND b.revoked_at IS NULL\n             AND COALESCE(b.channel_chat_id, b.channel_user_id) = channel_deliveries.channel_chat_id\n         )\n         AND NOT EXISTS (\n           SELECT 1 FROM channel_deliveries older\n           WHERE older.channel = channel_deliveries.channel\n             AND older.uid = channel_deliveries.uid\n             AND older.channel_chat_id = channel_deliveries.channel_chat_id\n             AND older.rowid < channel_deliveries.rowid\n             AND older.state IN ('pending', 'retry', 'delivering')\n         )\n         AND (\n           (state IN ('pending', 'retry') AND next_attempt_at <= ?1) OR\n           (state = 'delivering' AND lease_until < ?1)\n         )\n       RETURNING id, uid, channel, channel_chat_id, text, attempts, idempotency_key, lease_token";

async fn claim(
    db: &worker::D1Database,
    id: &str,
    now: i64,
    uid: &str,
    channel: Channel,
) -> Result<Option<DeliveryRow>> {
    let lease_token = random_uuid();
    let row = db
        .prepare(CLAIM_SQL)
        .bind(&[
            (now as f64).into(),
            ((now + delivery::LEASE_MS) as f64).into(),
            id.into(),
            (MAX_ATTEMPTS as f64).into(),
            lease_token.into(),
            uid.into(),
            channel.as_str().into(),
        ])?
        .first::<Value>(None)
        .await?;
    Ok(row.as_ref().and_then(row_to_delivery))
}

/// `requestFor` — build the provider send request, or `None` when credentials
/// are missing.
fn request_for(delivery: &DeliveryRow, env: &Env) -> Result<Option<Request>> {
    match delivery.channel {
        Channel::Telegram => {
            let Some(token) = env.secret("TELEGRAM_BOT_TOKEN").ok().map(|v| v.to_string()) else {
                return Ok(None);
            };
            let token = env
                .var("TELEGRAM_BOT_TOKEN")
                .ok()
                .map(|v| v.to_string())
                .filter(|v| !v.is_empty())
                .unwrap_or(token);
            if token.is_empty() {
                return Ok(None);
            }
            let url = format!("https://api.telegram.org/bot{token}/sendMessage");
            let mut init = RequestInit::new();
            init.with_method(Method::Post);
            let headers = Headers::new();
            headers.set("content-type", "application/json")?;
            init.with_headers(headers);
            let body = json!({ "chat_id": delivery.channel_chat_id, "text": delivery.text });
            init.with_body(Some(JsValue::from_str(&body.to_string())));
            Ok(Some(Request::new_with_init(&url, &init)?))
        }
        Channel::Blooio => {
            let key = env
                .secret("BLOOIO_API_KEY")
                .ok()
                .map(|v| v.to_string())
                .or_else(|| env.var("BLOOIO_API_KEY").ok().map(|v| v.to_string()))
                .filter(|v| !v.is_empty());
            let Some(key) = key else {
                return Ok(None);
            };
            let url = format!(
                "https://api.blooio.com/v2/api/chats/{}/messages",
                percent_encode(&delivery.channel_chat_id)
            );
            let mut init = RequestInit::new();
            init.with_method(Method::Post);
            let headers = Headers::new();
            headers.set("authorization", &format!("Bearer {key}"))?;
            headers.set("content-type", "application/json")?;
            headers.set(
                "idempotency-key",
                &stable_idempotency_key(&delivery.uid, delivery.channel, &delivery.idempotency_key),
            )?;
            init.with_headers(headers);
            init.with_body(Some(JsValue::from_str(
                &json!({ "text": delivery.text }).to_string(),
            )));
            Ok(Some(Request::new_with_init(&url, &init)?))
        }
    }
}

fn response_message_id(body: &Value) -> Option<String> {
    let candidate = body
        .get("result")
        .and_then(|r| r.get("message_id"))
        .or_else(|| body.get("message_id"))
        .or_else(|| body.get("id"))?;
    match candidate {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// Parse the retry hints out of a provider error response.
fn retry_after_hints(header: Option<String>, body: &Value) -> RetryAfterHints {
    let mut hints = RetryAfterHints::default();
    if let Some(header) = header.as_ref() {
        match header.trim().parse::<f64>() {
            Ok(seconds) if seconds.is_finite() => hints.header_seconds = Some(seconds),
            _ => {
                // Parity with `Date.parse(header)`.
                let ms = worker::js_sys::Date::parse(header);
                if ms.is_finite() {
                    hints.header_date_ms = Some(ms);
                }
            }
        }
    }
    let json_value = body
        .get("parameters")
        .and_then(|p| p.get("retry_after"))
        .or_else(|| body.get("retry_after"))
        .and_then(Value::as_f64);
    if let Some(value) = json_value {
        if value.is_finite() {
            hints.json_retry_after_seconds = Some(value);
        }
    }
    hints
}

async fn run_update(
    db: &worker::D1Database,
    sql: &str,
    mut values: Vec<JsValue>,
    id: &str,
    lease_token: &str,
) -> Result<()> {
    values.push(id.into());
    values.push(lease_token.into());
    db.prepare(sql).bind(&values)?.run().await?;
    Ok(())
}

async fn deliver_channel_message(
    env: &Env,
    id: &str,
    now: i64,
    uid: &str,
    channel: Channel,
) -> Result<()> {
    let db = env.d1("DB")?;
    let Some(delivery) = claim(&db, id, now, uid, channel).await? else {
        return Ok(());
    };
    let Some(request) = request_for(&delivery, env)? else {
        run_update(
            &db,
            "UPDATE channel_deliveries SET state = 'failed', lease_until = NULL, lease_token = NULL, last_error = 'Provider credentials unavailable', updated_at = ?1 WHERE id = ?2 AND state = 'delivering' AND lease_token = ?3",
            vec![(now as f64).into()],
            &delivery.id,
            &delivery.lease_token,
        )
        .await?;
        return Ok(());
    };

    match Fetch::Request(request).send().await {
        Ok(mut response) => {
            let status = response.status_code();
            if (200..300).contains(&status) {
                let body: Value = response.json().await.unwrap_or(Value::Null);
                let message_id = response_message_id(&body);
                run_update(
                    &db,
                    "UPDATE channel_deliveries SET state = 'sent', lease_until = NULL, lease_token = NULL, provider_message_id = ?1, last_error = NULL, sent_at = ?2, updated_at = ?2 WHERE id = ?3 AND state = 'delivering' AND lease_token = ?4",
                    vec![
                        message_id.map(JsValue::from).unwrap_or(JsValue::NULL),
                        (now as f64).into(),
                    ],
                    &delivery.id,
                    &delivery.lease_token,
                )
                .await?;
                return Ok(());
            }
            let header = response.headers().get("retry-after").ok().flatten();
            let body: Value = response.json().await.unwrap_or(Value::Null);
            let hints = retry_after_hints(header, &body);
            let state = http_outcome(status, delivery.attempts);
            let delay = retry_delay(delivery.attempts, &hints, now as f64, random_jitter());
            run_update(
                &db,
                "UPDATE channel_deliveries SET state = ?1, lease_until = NULL, lease_token = NULL, next_attempt_at = ?2, last_error = ?3, updated_at = ?4 WHERE id = ?5 AND state = 'delivering' AND lease_token = ?6",
                vec![
                    state.into(),
                    ((now + delay) as f64).into(),
                    format!("Provider HTTP {status}").into(),
                    (now as f64).into(),
                ],
                &delivery.id,
                &delivery.lease_token,
            )
            .await?;
        }
        Err(_) => {
            let state = network_outcome(delivery.channel, delivery.attempts);
            let delay = retry_delay(
                delivery.attempts,
                &RetryAfterHints::default(),
                now as f64,
                random_jitter(),
            );
            run_update(
                &db,
                "UPDATE channel_deliveries SET state = ?1, lease_until = NULL, lease_token = NULL, next_attempt_at = ?2, last_error = ?3, updated_at = ?4 WHERE id = ?5 AND state = 'delivering' AND lease_token = ?6",
                vec![
                    state.into(),
                    ((now + delay) as f64).into(),
                    network_error_message(delivery.channel).into(),
                    (now as f64).into(),
                ],
                &delivery.id,
                &delivery.lease_token,
            )
            .await?;
        }
    }
    Ok(())
}

async fn unlink_channel(env: &Env, uid: &str, channel: Channel, now: i64) -> Result<()> {
    let db = env.d1("DB")?;
    let results = db
        .batch(vec![
            db.prepare("UPDATE channel_bindings SET revoked_at = ?1 WHERE uid = ?2 AND channel = ?3 AND revoked_at IS NULL")
                .bind(&[(now as f64).into(), uid.into(), channel.as_str().into()])?,
            db.prepare("UPDATE channel_link_tokens SET consumed_at = ?1 WHERE uid = ?2 AND channel = ?3 AND consumed_at IS NULL")
                .bind(&[(now as f64).into(), uid.into(), channel.as_str().into()])?,
            db.prepare("UPDATE channel_deliveries\n       SET state = 'cancelled', lease_until = NULL, lease_token = NULL,\n           last_error = 'Channel unlinked', updated_at = ?1\n       WHERE uid = ?2 AND channel = ?3 AND state NOT IN ('sent', 'cancelled')")
                .bind(&[(now as f64).into(), uid.into(), channel.as_str().into()])?,
        ])
        .await?;
    let changes = results
        .first()
        .map(|r| r.meta().ok().flatten().and_then(|m| m.changes).unwrap_or(0))
        .unwrap_or(0);
    if changes > 0 {
        db.prepare(
            "INSERT INTO audit_events (id, uid, actor_type, action, target_type, target_id, details, created_at) VALUES (?1, ?2, 'owner', 'channel.unlinked', 'channel', ?3, ?4, ?5)",
        )
        .bind(&[
            random_uuid().into(),
            uid.into(),
            channel.as_str().into(),
            json!({ "revokedBindings": changes }).to_string().into(),
            (now as f64).into(),
        ])?
        .run()
        .await?;
    }
    Ok(())
}

async fn cancel_orphan_deliveries(env: &Env, uid: &str, channel: Channel, now: i64) -> Result<()> {
    let db = env.d1("DB")?;
    db.prepare(
        "UPDATE channel_deliveries SET state = 'cancelled', lease_until = NULL, lease_token = NULL,\n       last_error = 'Channel unlinked', updated_at = ?1\n     WHERE uid = ?2 AND channel = ?3 AND state NOT IN ('sent', 'cancelled') AND NOT EXISTS (\n       SELECT 1 FROM channel_bindings b\n       WHERE b.uid = channel_deliveries.uid AND b.channel = channel_deliveries.channel\n         AND b.revoked_at IS NULL\n         AND COALESCE(b.channel_chat_id, b.channel_user_id) = channel_deliveries.channel_chat_id\n     )",
    )
    .bind(&[(now as f64).into(), uid.into(), channel.as_str().into()])?
    .run()
    .await?;
    Ok(())
}

/// The `DeliveryCoordinator` Durable Object (per-uid/channel serialization).
#[durable_object]
pub struct DeliveryCoordinator {
    state: State,
    env: Env,
}

impl DurableObject for DeliveryCoordinator {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        match self.dispatch(&mut req).await {
            Ok(()) => Ok(Response::empty()?.with_status(204)),
            Err(_) => error_json("Delivery coordination failed", 500),
        }
    }
}

impl DeliveryCoordinator {
    async fn dispatch(&self, req: &mut Request) -> Result<()> {
        let path = req.path();
        let body: Value = req
            .json()
            .await
            .map_err(|_| worker::Error::RustError("bad body".into()))?;
        let uid = body.get("uid").and_then(Value::as_str);
        let channel = body
            .get("channel")
            .and_then(Value::as_str)
            .and_then(Channel::parse);
        let now = body
            .get("now")
            .and_then(Value::as_i64)
            .unwrap_or_else(now_ms);
        let (Some(uid), Some(channel)) = (uid, channel) else {
            return Err(worker::Error::RustError("identity mismatch".into()));
        };
        // Identity fencing: this DO must be the one named for (uid, channel).
        let expected = self
            .env
            .durable_object("DELIVERY_COORDINATOR")?
            .id_from_name(&coordinator_name(uid, channel))?
            .to_string();
        if self.state.id().to_string() != expected {
            return Err(worker::Error::RustError("identity mismatch".into()));
        }
        match path.as_str() {
            "/deliver" => {
                let Some(id) = body.get("id").and_then(Value::as_str) else {
                    return Err(worker::Error::RustError("invalid request".into()));
                };
                deliver_channel_message(&self.env, id, now, uid, channel).await
            }
            "/unlink" => unlink_channel(&self.env, uid, channel, now).await,
            "/cancel-orphans" => cancel_orphan_deliveries(&self.env, uid, channel, now).await,
            _ => Err(worker::Error::RustError("invalid request".into())),
        }
    }
}

async fn dispatch_to_coordinator(
    env: &Env,
    uid: &str,
    channel: Channel,
    path: &str,
    body: &Value,
) -> Result<()> {
    let stub = env
        .durable_object("DELIVERY_COORDINATOR")?
        .id_from_name(&coordinator_name(uid, channel))?
        .get_stub()?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let req = Request::new_with_init(&format!("https://delivery.internal{path}"), &init)?;
    let response = stub.fetch_with_request(req).await?;
    if response.status_code() >= 300 {
        return Err(worker::Error::RustError(
            "Delivery coordinator unavailable".into(),
        ));
    }
    Ok(())
}

/// `deliverDueChannelMessages` — the scheduled dispatch pass.
pub async fn deliver_due_channel_messages(env: &Env) -> Result<()> {
    let now = now_ms();
    let db = env.d1("DB")?;
    let orphans = db
        .prepare(
            "SELECT DISTINCT d.uid, d.channel FROM channel_deliveries d\n     WHERE d.state NOT IN ('sent', 'cancelled') AND NOT EXISTS (\n       SELECT 1 FROM channel_bindings b\n       WHERE b.uid = d.uid AND b.channel = d.channel\n         AND b.revoked_at IS NULL\n         AND COALESCE(b.channel_chat_id, b.channel_user_id) = d.channel_chat_id\n     )",
        )
        .all()
        .await?;
    for row in orphans.results::<Value>()? {
        if let (Some(uid), Some(channel)) = (
            json_str(&row, "uid"),
            json_str(&row, "channel")
                .as_deref()
                .and_then(Channel::parse),
        ) {
            let _ = dispatch_to_coordinator(
                env,
                &uid,
                channel,
                "/cancel-orphans",
                &json!({ "uid": uid, "channel": channel.as_str(), "now": now }),
            )
            .await;
        }
    }
    let rows = db
        .prepare(
            "SELECT d.id, d.uid, d.channel FROM channel_deliveries d\n     WHERE d.attempts < ?1 AND (\n       (d.state IN ('pending', 'retry') AND d.next_attempt_at <= ?2) OR\n       (d.state = 'delivering' AND d.lease_until < ?2)\n     ) AND NOT EXISTS (\n       SELECT 1 FROM channel_deliveries older\n       WHERE older.uid = d.uid AND older.channel = d.channel AND older.channel_chat_id = d.channel_chat_id\n         AND older.rowid < d.rowid\n         AND older.state IN ('pending', 'retry', 'delivering')\n     ) ORDER BY d.next_attempt_at LIMIT 25",
        )
        .bind(&[(MAX_ATTEMPTS as f64).into(), (now as f64).into()])?
        .all()
        .await?;
    for row in rows.results::<Value>()? {
        if let (Some(id), Some(uid), Some(channel)) = (
            json_str(&row, "id"),
            json_str(&row, "uid"),
            json_str(&row, "channel")
                .as_deref()
                .and_then(Channel::parse),
        ) {
            let _ = dispatch_to_coordinator(
                env,
                &uid,
                channel,
                "/deliver",
                &json!({ "id": id, "uid": uid, "channel": channel.as_str(), "now": now }),
            )
            .await;
        }
    }
    Ok(())
}

// ===========================================================================
// inbox-fallback.ts — unclaimed-inbox responder
// ===========================================================================

// Cross-group wiring: the inbox fallback responder composes replies from three
// implementations owned by other module groups, now landed in this crate:
//   - runManagedInboxCompletion  -> routes_ai::run_managed_inbox_completion
//   - memoryContextFor           -> routes_memory::memory_context_for
//   - completeInboxItemDone      -> glue::complete_inbox_done
// The lease-claim fencing and retry/ack transitions below drive `channel_inbox`
// on their own.

async fn managed_inbox_completion(
    env: &Env,
    uid: &str,
    messages: &[fallback::Message],
) -> Option<String> {
    let managed: Vec<crate::managed_ai::Message> = messages
        .iter()
        .map(|m| crate::managed_ai::Message {
            role: m.role.clone(),
            content: m.content.clone(),
        })
        .collect();
    crate::routes_ai::run_managed_inbox_completion(env, uid, &managed).await
}

async fn memory_context_for(env: &Env, uid: &str, text: &str) -> Option<String> {
    crate::routes_memory::memory_context_for(env, uid, text).await
}

struct InboxDoneResult {
    ok: bool,
    error: String,
}

async fn complete_inbox_item_done(
    env: &Env,
    uid: &str,
    id: &str,
    lease_token: &str,
    reply: &str,
    now: i64,
) -> InboxDoneResult {
    let db = match env.d1("DB") {
        Ok(db) => db,
        Err(_) => {
            return InboxDoneResult {
                ok: false,
                error: "Inbox completion unavailable".to_string(),
            }
        }
    };
    match crate::glue::complete_inbox_done(env, &db, uid, id, lease_token, reply, now as f64).await
    {
        Ok(Ok(_)) => InboxDoneResult {
            ok: true,
            error: String::new(),
        },
        Ok(Err(error)) => InboxDoneResult { ok: false, error },
        Err(_) => InboxDoneResult {
            ok: false,
            error: "Inbox completion failed".to_string(),
        },
    }
}

async fn recent_history(env: &Env, uid: &str) -> Result<Vec<fallback::Message>> {
    let db = env.d1("DB")?;
    let rows = db
        .prepare(
            "SELECT role, text FROM conversation_messages\n       WHERE uid = ?1 AND conversation_id = ?1\n       ORDER BY cursor DESC LIMIT ?2",
        )
        .bind(&[uid.into(), (fallback::HISTORY_LIMIT as f64).into()])?
        .all()
        .await?;
    // Newest-first from SQL; reverse to chronological for `shape_history`.
    let mut chronological: Vec<(String, String)> = rows
        .results::<Value>()?
        .into_iter()
        .filter_map(|row| Some((json_str(&row, "role")?, json_str(&row, "text")?)))
        .collect();
    chronological.reverse();
    Ok(fallback::shape_history(&chronological))
}

async fn release_for_retry(
    env: &Env,
    id: &str,
    uid: &str,
    lease_token: &str,
    error: &str,
) -> Result<()> {
    let db = env.d1("DB")?;
    db.prepare(
        "UPDATE channel_inbox\n     SET status = CASE WHEN attempts < ?1 THEN 'pending' ELSE 'failed' END,\n         lease_until = NULL, lease_token = NULL, last_error = ?2,\n         completed_at = CASE WHEN attempts >= ?1 THEN ?3 ELSE NULL END\n     WHERE id = ?4 AND uid = ?5 AND status = 'processing' AND lease_token = ?6",
    )
    .bind(&[
        (fallback::MAX_ATTEMPTS as f64).into(),
        error.into(),
        (now_ms() as f64).into(),
        id.into(),
        uid.into(),
        lease_token.into(),
    ])?
    .run()
    .await?;
    Ok(())
}

async fn respond_to_item(env: &Env, id: &str, uid: &str, now: i64) -> Result<()> {
    let db = env.d1("DB")?;
    let lease_token = random_uuid();
    let item = db
        .prepare(
            "UPDATE channel_inbox\n     SET status = 'processing', attempts = attempts + 1, lease_until = ?3,\n         lease_token = ?4, last_error = NULL\n     WHERE id = ?1 AND uid = ?2 AND status = 'pending' AND attempts < ?5\n       AND received_at <= ?6\n     RETURNING id, channel, text, attempts",
        )
        .bind(&[
            id.into(),
            uid.into(),
            ((now + fallback::FALLBACK_LEASE_MS) as f64).into(),
            lease_token.clone().into(),
            (fallback::MAX_ATTEMPTS as f64).into(),
            ((now - fallback::FALLBACK_CLAIM_DELAY_MS) as f64).into(),
        ])?
        .first::<Value>(None)
        .await?;
    let Some(item) = item else {
        return Ok(());
    };
    let text = json_str(&item, "text").unwrap_or_default();
    let attempts = json_i64(&item, "attempts").unwrap_or(0) as u32;

    let mut reply = if env_has_active_pro(env, uid).await {
        let memory_context = memory_context_for(env, uid, &text).await;
        let history = recent_history(env, uid).await.unwrap_or_default();
        let messages = fallback::build_messages(memory_context.as_deref(), &history, &text);
        match managed_inbox_completion(env, uid, &messages).await {
            Some(completion) => completion,
            None => {
                if attempts < fallback::MAX_ATTEMPTS {
                    release_for_retry(
                        env,
                        id,
                        uid,
                        &lease_token,
                        "Fallback completion unavailable",
                    )
                    .await?;
                    return Ok(());
                }
                fallback::OFFLINE_ACKNOWLEDGEMENT.to_string()
            }
        }
    } else {
        fallback::OFFLINE_ACKNOWLEDGEMENT.to_string()
    };
    reply = fallback::finalize_reply(&reply);
    let result = complete_inbox_item_done(env, uid, id, &lease_token, &reply, now_ms()).await;
    if !result.ok {
        release_for_retry(env, id, uid, &lease_token, &result.error).await?;
    }
    Ok(())
}

/// `respondToStaleInboxItems`.
pub async fn respond_to_stale_inbox_items(env: &Env) -> Result<()> {
    if fallback::responder_disabled(
        env.var("CHANNEL_FALLBACK_RESPONDER")
            .ok()
            .map(|v| v.to_string())
            .as_deref(),
    ) {
        return Ok(());
    }
    let now = now_ms();
    let db = env.d1("DB")?;
    let stale = db
        .prepare(
            "SELECT id, uid FROM channel_inbox\n     WHERE status = 'pending' AND attempts < ?1 AND received_at <= ?2\n     ORDER BY received_at, id LIMIT ?3",
        )
        .bind(&[
            (fallback::MAX_ATTEMPTS as f64).into(),
            ((now - fallback::FALLBACK_CLAIM_DELAY_MS) as f64).into(),
            (fallback::MAX_ITEMS_PER_RUN as f64).into(),
        ])?
        .all()
        .await?;
    for row in stale.results::<Value>()? {
        if let (Some(id), Some(uid)) = (json_str(&row, "id"), json_str(&row, "uid")) {
            let _ = respond_to_item(env, &id, &uid, now).await;
        }
    }
    Ok(())
}

/// `hasActivePro` against an `Env` (parity with entitlement.ts).
async fn env_has_active_pro(env: &Env, uid: &str) -> bool {
    let dev = env.var("DEV_FAKE_PRO").ok().map(|v| v.to_string());
    let environment = env.var("ENVIRONMENT").ok().map(|v| v.to_string());
    match crate::entitlement::dev_fake_pro(dev.as_deref(), environment.as_deref()) {
        crate::entitlement::DevFakePro::ForcePro => return true,
        crate::entitlement::DevFakePro::IgnoredInProduction
        | crate::entitlement::DevFakePro::NotSet => {}
    }
    let Ok(db) = env.d1("DB") else {
        return false;
    };
    let row = db
        .prepare("SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1")
        .bind(&[uid.into()])
        .ok();
    let Some(row) = row else { return false };
    let row = match row.first::<Value>(None).await {
        Ok(Some(row)) => crate::entitlement::EntitlementRow {
            plan: json_str(&row, "plan"),
            status: json_str(&row, "status"),
            valid_until: json_i64(&row, "valid_until"),
        },
        _ => crate::entitlement::EntitlementRow::default(),
    };
    crate::entitlement::row_grants_pro(&row, now_ms())
}

// ===========================================================================
// oauth-broker.ts + oauth-proxy.ts — device-code broker + subscription proxy
// ===========================================================================

thread_local! {
    // Pinned x.ai discovery cache (parity with the module-level `xaiDiscovery`).
    static XAI_DISCOVERY: RefCell<Option<(String, String)>> = const { RefCell::new(None) };
}

async fn discover_xai_endpoints() -> Option<(String, String)> {
    if let Some(cached) = XAI_DISCOVERY.with(|c| c.borrow().clone()) {
        return Some(cached);
    }
    let url = Url::parse("https://auth.x.ai/.well-known/openid-configuration").ok()?;
    let mut response = Fetch::Url(url).send().await.ok()?;
    if response.status_code() != 200 {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    let device = body
        .get("device_authorization_endpoint")
        .and_then(Value::as_str)?;
    let token = body.get("token_endpoint").and_then(Value::as_str)?;
    if !valid_xai_endpoint(device) || !valid_xai_endpoint(token) {
        return None;
    }
    let pair = (device.to_string(), token.to_string());
    XAI_DISCOVERY.with(|c| *c.borrow_mut() = Some(pair.clone()));
    Some(pair)
}

async fn provider_config(env: &Env, provider: &str) -> Option<ProviderConfig> {
    match provider {
        "openai" => openai_config(
            env.var("OPENAI_OAUTH_CLIENT_ID")
                .ok()
                .map(|v| v.to_string())
                .as_deref(),
        ),
        "xai" => {
            let client_id = env.var("XAI_OAUTH_CLIENT_ID").ok().map(|v| v.to_string());
            let (device, token) = discover_xai_endpoints().await?;
            xai_config(client_id.as_deref(), &device, &token)
        }
        _ => None,
    }
}

fn token_key(env: &Env) -> Option<[u8; 32]> {
    let secret = env
        .secret("OAUTH_TOKEN_KEY")
        .ok()
        .map(|v| v.to_string())
        .or_else(|| env.var("OAUTH_TOKEN_KEY").ok().map(|v| v.to_string()))
        .filter(|v| !v.is_empty())?;
    import_oauth_token_key(&secret)
}

fn random_iv() -> [u8; 12] {
    let mut iv = [0u8; 12];
    getrandom::getrandom(&mut iv).expect("getrandom");
    iv
}

fn json_response(value: Value, status: u16) -> Result<Response> {
    Ok(Response::from_json(&value)?.with_status(status))
}

/// The `ENABLE_DEV_OAUTH_BROKER` gate (parity with the `/oauth/*` middleware).
fn oauth_gate(ctx: &RouteContext<()>) -> Option<Response> {
    let enabled = ctx
        .env
        .var("ENABLE_DEV_OAUTH_BROKER")
        .ok()
        .map(|v| v.to_string());
    if enabled.as_deref() != Some("true") {
        return json_response(
            json!({ "error": "Disabled: dev/testing only OAuth broker is not enabled" }),
            403,
        )
        .ok();
    }
    None
}

async fn oauth_device_start(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let Some(response) = oauth_gate(&ctx) {
        return Ok(response);
    }
    let uid = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth.uid,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let (allowed, retry_after) =
        consume_rate_limit(&ctx.env, &format!("oauth-device-start:{uid}"), 5, 60_000).await?;
    if !allowed {
        let mut response = json_response(json!({ "error": "Too many requests" }), 429)?;
        response
            .headers_mut()
            .set("retry-after", &retry_after.to_string())?;
        return Ok(response);
    }
    let provider = ctx.param("provider").cloned().unwrap_or_default();
    let Some(config) = provider_config(&ctx.env, &provider).await else {
        return json_response(json!({ "error": "Provider unavailable" }), 503);
    };
    let body = form_encode(&[("client_id", &config.client_id), ("scope", &config.scope)]);
    let request = form_post(&config.device_endpoint, &body)?;
    let mut response = match Fetch::Request(request).send().await {
        Ok(response) => response,
        Err(_) => return json_response(json!({ "error": "Provider rejected device start" }), 502),
    };
    if !(200..300).contains(&response.status_code()) {
        return json_response(json!({ "error": "Provider rejected device start" }), 502);
    }
    let body: Value = response.json().await.unwrap_or(Value::Null);
    let device_code = json_str(&body, "device_code");
    let user_code = json_str(&body, "user_code");
    let (Some(device_code), Some(user_code)) = (device_code, user_code) else {
        return json_response(json!({ "error": "Provider rejected device start" }), 502);
    };
    let verification_uri = body
        .get("verification_uri_complete")
        .and_then(Value::as_str)
        .or_else(|| body.get("verification_uri").and_then(Value::as_str))
        .unwrap_or("");
    let interval = body.get("interval").and_then(Value::as_i64).unwrap_or(5);
    let expires_in = body
        .get("expires_in")
        .and_then(Value::as_i64)
        .unwrap_or(900);
    json_response(
        json!({
            "deviceCode": device_code,
            "userCode": user_code,
            "verificationUri": verification_uri,
            "interval": interval,
            "expiresIn": expires_in,
        }),
        200,
    )
}

async fn oauth_device_poll(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let Some(response) = oauth_gate(&ctx) {
        return Ok(response);
    }
    let uid = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth.uid,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let (allowed, retry_after) =
        consume_rate_limit(&ctx.env, &format!("oauth-device-poll:{uid}"), 30, 60_000).await?;
    if !allowed {
        let mut response = json_response(json!({ "error": "Too many requests" }), 429)?;
        response
            .headers_mut()
            .set("retry-after", &retry_after.to_string())?;
        return Ok(response);
    }
    let provider = ctx.param("provider").cloned().unwrap_or_default();
    let Some(config) = provider_config(&ctx.env, &provider).await else {
        return json_response(json!({ "error": "Provider unavailable" }), 503);
    };
    let Some(key) = token_key(&ctx.env) else {
        return json_response(json!({ "error": "Provider unavailable" }), 503);
    };
    let device_code = req
        .json::<Value>()
        .await
        .ok()
        .and_then(|b| json_str(&b, "deviceCode"));
    let Some(device_code) = device_code.filter(|d| d.len() <= 2048) else {
        return json_response(json!({ "error": "Invalid request" }), 400);
    };
    let body = form_encode(&[
        ("client_id", &config.client_id),
        ("device_code", &device_code),
        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
    ]);
    let request = form_post(&config.token_endpoint, &body)?;
    let mut response = match Fetch::Request(request).send().await {
        Ok(response) => response,
        Err(_) => return json_response(json!({ "error": "failed" }), 400),
    };
    let ok = (200..300).contains(&response.status_code());
    let body: Value = response.json().await.unwrap_or(Value::Null);
    let access_token = json_str(&body, "access_token");
    if !ok || access_token.is_none() {
        let error = body.get("error").and_then(Value::as_str);
        return match classify_poll_error(error) {
            PollOutcome::Pending(code) => {
                json_response(json!({ "pending": true, "error": code }), 202)
            }
            PollOutcome::Failed(code) => json_response(json!({ "error": code }), 400),
        };
    }
    let access_token = access_token.unwrap();
    let now = now_ms();
    let expires_at = connection_expires_at(now, body.get("expires_in").and_then(Value::as_f64));
    let db = ctx.env.d1("DB")?;
    let encrypted_access = encrypt_oauth_token(&key, &random_iv(), &access_token)
        .ok_or_else(|| worker::Error::RustError("encrypt".into()))?;
    let encrypted_refresh = match json_str(&body, "refresh_token") {
        Some(refresh) => encrypt_oauth_token(&key, &random_iv(), &refresh)
            .map(JsValue::from)
            .unwrap_or(JsValue::NULL),
        None => JsValue::NULL,
    };
    let account_id = json_str(&body, "account_id")
        .filter(|a| valid_account_id(a))
        .map(JsValue::from)
        .unwrap_or(JsValue::NULL);
    db.prepare(
        "INSERT INTO oauth_connections\n       (uid, provider, access_token, refresh_token, account_id, expires_at, created_at, updated_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)\n     ON CONFLICT (uid, provider) DO UPDATE SET\n       access_token = excluded.access_token,\n       refresh_token = excluded.refresh_token,\n       account_id = excluded.account_id,\n       expires_at = excluded.expires_at,\n       updated_at = excluded.updated_at",
    )
    .bind(&[
        uid.into(),
        provider.into(),
        encrypted_access.into(),
        encrypted_refresh,
        account_id,
        expires_at.map(|e| JsValue::from(e as f64)).unwrap_or(JsValue::NULL),
        (now as f64).into(),
    ])?
    .run()
    .await?;
    json_response(json!({ "connected": true }), 200)
}

async fn oauth_status(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let Some(response) = oauth_gate(&ctx) {
        return Ok(response);
    }
    let uid = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth.uid,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = ctx.env.d1("DB")?;
    let rows = db
        .prepare("SELECT provider, expires_at, updated_at FROM oauth_connections WHERE uid = ?1")
        .bind(&[uid.into()])?
        .all()
        .await?;
    let connections: Vec<Value> = rows
        .results::<Value>()?
        .into_iter()
        .map(|row| {
            json!({
                "provider": row.get("provider"),
                "expiresAt": row.get("expires_at"),
                "updatedAt": row.get("updated_at"),
            })
        })
        .collect();
    json_response(json!({ "connections": connections }), 200)
}

async fn oauth_delete(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let Some(response) = oauth_gate(&ctx) {
        return Ok(response);
    }
    let uid = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth.uid,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let provider = ctx.param("provider").cloned().unwrap_or_default();
    let db = ctx.env.d1("DB")?;
    db.prepare("DELETE FROM oauth_connections WHERE uid = ?1 AND provider = ?2")
        .bind(&[uid.into(), provider.into()])?
        .run()
        .await?;
    json_response(json!({ "disconnected": true }), 200)
}

struct Connection {
    access_token: String,
    refresh_token: Option<String>,
    account_id: Option<String>,
    expires_at: Option<i64>,
}

async fn oauth_proxy_chat(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    if let Some(response) = oauth_gate(&ctx) {
        return Ok(response);
    }
    let uid = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth.uid,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let provider = ctx.param("provider").cloned().unwrap_or_default();
    if provider != "openai" && provider != "xai" {
        return json_response(json!({ "error": "Not connected" }), 404);
    }
    // boundedJson: reject oversize bodies, require a JSON object.
    let body = match req.text().await {
        Ok(text) if text.len() <= 1_048_576 => serde_json::from_str::<Value>(&text)
            .ok()
            .filter(|v| v.is_object()),
        _ => None,
    };
    let Some(body) = body else {
        return json_response(json!({ "error": "Invalid request" }), 400);
    };
    let Some(key) = token_key(&ctx.env) else {
        return json_response(json!({ "error": "Not connected" }), 503);
    };
    let db = ctx.env.d1("DB")?;
    let connection = db
        .prepare("SELECT access_token, refresh_token, account_id, expires_at FROM oauth_connections WHERE uid = ?1 AND provider = ?2")
        .bind(&[uid.clone().into(), provider.clone().into()])?
        .first::<Value>(None)
        .await?;
    let Some(connection) = connection.map(|row| Connection {
        access_token: json_str(&row, "access_token").unwrap_or_default(),
        refresh_token: json_str(&row, "refresh_token"),
        account_id: json_str(&row, "account_id"),
        expires_at: json_i64(&row, "expires_at"),
    }) else {
        return json_response(json!({ "error": "Not connected" }), 404);
    };
    let Some(mut access_token) = decrypt_oauth_token(&key, &connection.access_token) else {
        return json_response(json!({ "error": "Reconnect required" }), 401);
    };
    let now = now_ms();

    if needs_refresh(connection.expires_at, now) {
        match refresh_access_token(&ctx.env, &db, &key, &uid, &provider, &connection, now).await {
            RefreshOutcome::Token(token) => access_token = token,
            RefreshOutcome::Reject(response) => return Ok(response),
        }
    }

    let headers = Headers::new();
    headers.set("authorization", &format!("Bearer {access_token}"))?;
    headers.set("content-type", "application/json")?;
    if provider == "openai" {
        headers.set("originator", "omi")?;
        if let Some(account_id) = &connection.account_id {
            headers.set("chatgpt-account-id", account_id)?;
        }
    }
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let upstream_url = if provider == "openai" {
        OPENAI_UPSTREAM
    } else {
        XAI_UPSTREAM
    };
    let request = Request::new_with_init(upstream_url, &init)?;
    let mut upstream = match Fetch::Request(request).send().await {
        Ok(response) => response,
        Err(_) => return json_response(json!({ "error": "Provider unavailable" }), 502),
    };
    let status = upstream.status_code();
    let content_type = upstream
        .headers()
        .get("content-type")
        .ok()
        .flatten()
        .unwrap_or_else(|| "application/json".to_string());
    let stream = upstream.stream()?;
    let response = Response::from_stream(stream)?.with_status(status);
    let out_headers = response.headers().clone();
    out_headers.set("cache-control", "no-store")?;
    out_headers.set("content-type", &content_type)?;
    out_headers.set("x-content-type-options", "nosniff")?;
    Ok(response.with_headers(out_headers))
}

enum RefreshOutcome {
    Token(String),
    Reject(Response),
}

async fn refresh_access_token(
    env: &Env,
    db: &worker::D1Database,
    key: &[u8; 32],
    uid: &str,
    provider: &str,
    connection: &Connection,
    now: i64,
) -> RefreshOutcome {
    let reject = |value: Value, status: u16| {
        RefreshOutcome::Reject(
            json_response(value, status)
                .unwrap_or_else(|_| Response::empty().unwrap().with_status(status)),
        )
    };
    let Some(stored_refresh) = &connection.refresh_token else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    let Some(config) = provider_config(env, provider).await else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    let Some(refresh_token) = decrypt_oauth_token(key, stored_refresh) else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    let lock_key = format!("oauth-refresh:{uid}:{provider}");
    let acquired = acquire_refresh_lock(env, &lock_key).await.unwrap_or(false);
    if !acquired {
        return reject(json!({ "error": "Refresh in progress, retry" }), 409);
    }
    let outcome = refresh_with_lock(
        db,
        key,
        uid,
        provider,
        connection,
        &config,
        &refresh_token,
        now,
    )
    .await;
    let _ = release_refresh_lock(env, &lock_key).await;
    outcome
}

#[allow(clippy::too_many_arguments)]
async fn refresh_with_lock(
    db: &worker::D1Database,
    key: &[u8; 32],
    uid: &str,
    provider: &str,
    connection: &Connection,
    config: &ProviderConfig,
    refresh_token: &str,
    now: i64,
) -> RefreshOutcome {
    let reject = |value: Value, status: u16| {
        RefreshOutcome::Reject(
            json_response(value, status)
                .unwrap_or_else(|_| Response::empty().unwrap().with_status(status)),
        )
    };
    let body = form_encode(&[
        ("client_id", &config.client_id),
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
    ]);
    let refreshed: Option<Value> = match form_post(&config.token_endpoint, &body) {
        Ok(request) => match Fetch::Request(request).send().await {
            Ok(mut response) if (200..300).contains(&response.status_code()) => {
                response.json().await.ok()
            }
            _ => None,
        },
        Err(_) => None,
    };
    let Some(refreshed) = refreshed else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    let Some(new_access) = json_str(&refreshed, "access_token") else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    let stored_refresh = connection.refresh_token.clone().unwrap_or_default();
    let rotated_refresh = match json_str(&refreshed, "refresh_token") {
        Some(refresh) => {
            encrypt_oauth_token(key, &random_iv(), &refresh).unwrap_or(stored_refresh.clone())
        }
        None => stored_refresh.clone(),
    };
    let expires_at = refreshed_expires_at(now, refreshed.get("expires_in").and_then(Value::as_f64));
    let Some(encrypted_access) = encrypt_oauth_token(key, &random_iv(), &new_access) else {
        return reject(json!({ "error": "Reconnect required" }), 401);
    };
    // Compare-and-swap rotation keyed on the old refresh token.
    let rotation = db
        .prepare("UPDATE oauth_connections SET access_token = ?1, refresh_token = ?2, expires_at = ?3, updated_at = ?4 WHERE uid = ?5 AND provider = ?6 AND refresh_token = ?7")
        .bind(&[
            encrypted_access.into(),
            rotated_refresh.into(),
            (expires_at as f64).into(),
            (now as f64).into(),
            uid.into(),
            provider.into(),
            stored_refresh.into(),
        ]);
    let changes = match rotation {
        Ok(stmt) => match stmt.run().await {
            Ok(result) => result
                .meta()
                .ok()
                .flatten()
                .and_then(|m| m.changes)
                .unwrap_or(0),
            Err(_) => return reject(json!({ "error": "Reconnect required" }), 401),
        },
        Err(_) => return reject(json!({ "error": "Reconnect required" }), 401),
    };
    if changes == 0 {
        // Lost the race: re-read the winner's token.
        let winner = db
            .prepare("SELECT access_token FROM oauth_connections WHERE uid = ?1 AND provider = ?2")
            .bind(&[uid.into(), provider.into()])
            .ok();
        let winner_token = match winner {
            Some(stmt) => match stmt.first::<Value>(None).await {
                Ok(Some(row)) => {
                    json_str(&row, "access_token").and_then(|t| decrypt_oauth_token(key, &t))
                }
                _ => None,
            },
            None => None,
        };
        return match winner_token {
            Some(token) => RefreshOutcome::Token(token),
            None => reject(json!({ "error": "Reconnect required" }), 401),
        };
    }
    RefreshOutcome::Token(new_access)
}

// ===========================================================================
// Route registration
// ===========================================================================

/// Merge seam: extend the shared Router with this group's OAuth routes.
pub fn register(router: Router<'_, ()>) -> Router<'_, ()> {
    router
        .post_async("/v1/oauth/:provider/chat/completions", oauth_proxy_chat)
        .post_async("/v1/oauth/:provider/device/start", oauth_device_start)
        .post_async("/v1/oauth/:provider/device/poll", oauth_device_poll)
        .get_async("/v1/oauth/status", oauth_status)
        .delete_async("/v1/oauth/:provider", oauth_delete)
}
