//! workers-rs glue for the delivery group. Compiled only for wasm32.
//!
//! Behaviour parity with `worker/src/delivery.ts` and
//! `worker/src/inbox-fallback.ts`. The pure decision logic lives in
//! `crate::delivery` and `crate::inbox_fallback`; this file is the thin I/O
//! layer (Durable Object, D1, provider `fetch`) that drives them.

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::*;

use crate::channel_commands as cmd;
use crate::channel_link;
use crate::delivery::{
    self, coordinator_name, http_outcome, network_error_message, network_outcome, retry_delay,
    stable_idempotency_key, Channel, RetryAfterHints, MAX_ATTEMPTS,
};
use crate::glue::error_json;
use crate::inbox_fallback as fallback;
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

/// Build a provider send request — the single outbound path for both queued
/// deliveries and control-plane replies. Telegram goes through the real Bot API
/// `sendMessage` method with `chat_id` + plain-text `text` (no `parse_mode`, so
/// no MarkdownV2 escaping is required). `None` when credentials are missing.
fn provider_send_request(
    env: &Env,
    channel: Channel,
    chat_id: &str,
    text: &str,
    idempotency_key: Option<&str>,
) -> Result<Option<Request>> {
    match channel {
        Channel::Telegram => {
            let token = env
                .secret("TELEGRAM_BOT_TOKEN")
                .ok()
                .map(|v| v.to_string())
                .or_else(|| env.var("TELEGRAM_BOT_TOKEN").ok().map(|v| v.to_string()))
                .filter(|v| !v.is_empty());
            let Some(token) = token else {
                return Ok(None);
            };
            let url = format!("https://api.telegram.org/bot{token}/sendMessage");
            let mut init = RequestInit::new();
            init.with_method(Method::Post);
            let headers = Headers::new();
            headers.set("content-type", "application/json")?;
            init.with_headers(headers);
            let body = json!({ "chat_id": chat_id, "text": text });
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
                percent_encode(chat_id)
            );
            let mut init = RequestInit::new();
            init.with_method(Method::Post);
            let headers = Headers::new();
            headers.set("authorization", &format!("Bearer {key}"))?;
            headers.set("content-type", "application/json")?;
            if let Some(key) = idempotency_key {
                headers.set("idempotency-key", key)?;
            }
            init.with_headers(headers);
            init.with_body(Some(JsValue::from_str(
                &json!({ "text": text }).to_string(),
            )));
            Ok(Some(Request::new_with_init(&url, &init)?))
        }
    }
}

// ---------------------------------------------------------------------------
// channel-link.ts + channel-commands.ts — reverse linking + shared command
// dispatcher (parity). Both channels are thin transports over this one path.
// ---------------------------------------------------------------------------

fn channel_webhook_secret(env: &Env, channel: Channel) -> Option<String> {
    let name = match channel {
        Channel::Telegram => "TELEGRAM_WEBHOOK_SECRET",
        Channel::Blooio => "BLOOIO_WEBHOOK_SIGNING_SECRET",
    };
    env.secret(name)
        .ok()
        .map(|v| v.to_string())
        .or_else(|| env.var(name).ok().map(|v| v.to_string()))
        .filter(|v| !v.is_empty())
}

/// `issueLinkCode`: re-derive the outstanding code for a sender, or mint one.
pub async fn issue_link_code(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<Option<(String, i64)>> {
    let Some(secret) = channel_webhook_secret(env, channel) else {
        return Ok(None);
    };
    let db = env.d1("DB")?;
    let pending = db
        .prepare(
            "SELECT nonce, expires_at FROM channel_link_codes\n     WHERE channel = ?1 AND channel_user_id = ?2 AND consumed_at IS NULL AND expires_at > ?3\n     ORDER BY expires_at DESC LIMIT 1",
        )
        .bind(&[
            channel.as_str().into(),
            channel_user_id.into(),
            (now as f64).into(),
        ])?
        .first::<Value>(None)
        .await?;
    if let Some(pending) = pending {
        let nonce = json_str(&pending, "nonce").unwrap_or_default();
        let expires_at = json_i64(&pending, "expires_at").unwrap_or(now);
        let code =
            channel_link::derive_link_code(&secret, channel.as_str(), channel_user_id, &nonce);
        return Ok(Some((code, expires_at)));
    }
    let nonce = random_uuid();
    let code = channel_link::derive_link_code(&secret, channel.as_str(), channel_user_id, &nonce);
    let expires_at = now + channel_link::LINK_CODE_TTL_MS;
    db.prepare(
        "INSERT INTO channel_link_codes\n       (code_hash, channel, channel_user_id, channel_chat_id, nonce, expires_at, created_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)\n     ON CONFLICT(code_hash) DO UPDATE SET\n       channel_chat_id = excluded.channel_chat_id,\n       expires_at = excluded.expires_at,\n       consumed_at = NULL",
    )
    .bind(&[
        channel_link::code_hash(&code).into(),
        channel.as_str().into(),
        channel_user_id.into(),
        channel_chat_id.into(),
        nonce.into(),
        (expires_at as f64).into(),
        (now as f64).into(),
    ])?
    .run()
    .await?;
    Ok(Some((code, expires_at)))
}

/// A code resolved to the chat it was issued to.
pub struct PendingLinkCode {
    pub channel: Channel,
    pub channel_user_id: String,
    pub channel_chat_id: String,
    pub code_hash: String,
}

/// `resolveLinkCode`: look up a live, unconsumed code.
pub async fn resolve_link_code(env: &Env, code: &str, now: i64) -> Result<Option<PendingLinkCode>> {
    let db = env.d1("DB")?;
    let code_hash = channel_link::code_hash(code);
    let row = db
        .prepare(
            "SELECT channel, channel_user_id, channel_chat_id FROM channel_link_codes\n     WHERE code_hash = ?1 AND consumed_at IS NULL AND expires_at > ?2",
        )
        .bind(&[code_hash.clone().into(), (now as f64).into()])?
        .first::<Value>(None)
        .await?;
    let Some(row) = row else {
        return Ok(None);
    };
    let channel = match json_str(&row, "channel").as_deref() {
        Some("telegram") => Channel::Telegram,
        Some("blooio") => Channel::Blooio,
        _ => return Ok(None),
    };
    Ok(Some(PendingLinkCode {
        channel,
        channel_user_id: json_str(&row, "channel_user_id").unwrap_or_default(),
        channel_chat_id: json_str(&row, "channel_chat_id").unwrap_or_default(),
        code_hash,
    }))
}

struct ChannelBinding {
    uid: String,
    verified_at: i64,
    email: Option<String>,
}

async fn channel_binding(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
) -> Result<Option<ChannelBinding>> {
    let db = env.d1("DB")?;
    let row = db
        .prepare(
            "SELECT b.uid AS uid, b.verified_at AS verified_at, u.email AS email\n     FROM channel_bindings b LEFT JOIN users u ON u.uid = b.uid\n     WHERE b.channel = ?1 AND b.channel_user_id = ?2 AND b.revoked_at IS NULL",
        )
        .bind(&[channel.as_str().into(), channel_user_id.into()])?
        .first::<Value>(None)
        .await?;
    Ok(row.map(|row| ChannelBinding {
        uid: json_str(&row, "uid").unwrap_or_default(),
        verified_at: json_i64(&row, "verified_at").unwrap_or(0),
        email: json_str(&row, "email"),
    }))
}

async fn unlinked_reply_allowed(env: &Env, channel: Channel, channel_user_id: &str) -> bool {
    // Shares the one canonical rate limiter with the managed-AI routes; the
    // deletion pass removed the old standalone module this used to call.
    let (allowed, _) = crate::routes_ai::consume_rate_limit(
        env,
        &format!("channel-link-code:{}:{channel_user_id}", channel.as_str()),
        5,
        60 * 60_000,
    )
    .await;
    allowed
}

/// The outcome of dispatching an inbound message: an optional immediate reply
/// and whether the message should reach the assistant inbox.
pub struct ChannelOutcome {
    pub reply: Option<String>,
    pub enqueue: bool,
}

async fn start_link(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<ChannelOutcome> {
    if !unlinked_reply_allowed(env, channel, channel_user_id).await {
        return Ok(ChannelOutcome {
            reply: None,
            enqueue: false,
        });
    }
    match issue_link_code(env, channel, channel_user_id, channel_chat_id, now).await? {
        Some((code, _)) => Ok(ChannelOutcome {
            reply: Some(cmd::greeting_text(&code)),
            enqueue: false,
        }),
        None => Ok(ChannelOutcome {
            reply: None,
            enqueue: false,
        }),
    }
}

/// `handleChannelMessage`: the one shared dispatcher, run before the assistant.
pub async fn handle_channel_message(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    text: &str,
    now: i64,
) -> Result<ChannelOutcome> {
    let binding = channel_binding(env, channel, channel_user_id).await?;
    let Some(parsed) = cmd::parse_command(text) else {
        return if binding.is_some() {
            Ok(ChannelOutcome {
                reply: None,
                enqueue: true,
            })
        } else {
            start_link(env, channel, channel_user_id, channel_chat_id, now).await
        };
    };
    let Some(command) = cmd::resolve_command(&parsed.command) else {
        if binding.is_none() && !unlinked_reply_allowed(env, channel, channel_user_id).await {
            return Ok(ChannelOutcome {
                reply: None,
                enqueue: false,
            });
        }
        return Ok(ChannelOutcome {
            reply: Some(cmd::UNKNOWN_COMMAND_TEXT.to_string()),
            enqueue: false,
        });
    };
    let Some(binding) = binding else {
        if command.name != "/start" {
            if !unlinked_reply_allowed(env, channel, channel_user_id).await {
                return Ok(ChannelOutcome {
                    reply: None,
                    enqueue: false,
                });
            }
            let reply = if command.name == "/help" {
                cmd::channel_help_text()
            } else {
                cmd::NOT_LINKED_TEXT.to_string()
            };
            return Ok(ChannelOutcome {
                reply: Some(reply),
                enqueue: false,
            });
        }
        return start_link(env, channel, channel_user_id, channel_chat_id, now).await;
    };
    let masked = cmd::mask_email(binding.email.as_deref());
    let reply = match command.name {
        "/help" => cmd::channel_help_text(),
        "/start" => format!(
            "This chat is already linked to {masked}. Just send me a message and I'll \
answer. /help lists what else I understand here."
        ),
        "/status" => {
            let day = cmd::iso_date(binding.verified_at);
            format!("Linked to {masked} since {day}. Send /logout to disconnect this chat.")
        }
        "/whoami" => {
            format!("I'm answering as {masked} — the Omi account this chat is linked to.")
        }
        "/reset" => {
            reset_conversation(env, channel, channel_user_id, &binding.uid).await?;
            "Fresh start — I've dropped the earlier conversation from this chat's context. \
Your account stays linked."
                .to_string()
        }
        _ => {
            // /logout (or /unlink).
            if !parsed.argument.eq_ignore_ascii_case("confirm") {
                format!(
                    "Unlinking disconnects this chat from {masked}: I'll stop answering here \
until you link again. Send /logout confirm to go ahead."
                )
            } else {
                match dispatch_to_coordinator(
                    env,
                    &binding.uid,
                    channel,
                    "/unlink",
                    &json!({ "uid": binding.uid, "channel": channel.as_str() }),
                )
                .await
                {
                    Ok(()) => "Unlinked. This chat is no longer connected to your Omi account — \
send /start whenever you want to link it again."
                        .to_string(),
                    Err(_) => "I couldn't unlink this chat just now. Try again in a moment, or \
unlink it from Omi's settings."
                        .to_string(),
                }
            }
        }
    };
    Ok(ChannelOutcome {
        reply: Some(reply),
        enqueue: false,
    })
}

async fn reset_conversation(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    uid: &str,
) -> Result<()> {
    let db = env.d1("DB")?;
    db.prepare(
        "UPDATE channel_bindings SET conversation_reset_cursor =\n       (SELECT COALESCE(MAX(cursor), 0) FROM conversation_messages\n        WHERE uid = ?1 AND conversation_id = ?1)\n     WHERE channel = ?2 AND channel_user_id = ?3 AND revoked_at IS NULL",
    )
    .bind(&[uid.into(), channel.as_str().into(), channel_user_id.into()])?
    .run()
    .await?;
    Ok(())
}

/// `requestFor` — build the provider send request for a queued delivery.
fn request_for(delivery: &DeliveryRow, env: &Env) -> Result<Option<Request>> {
    let idempotency = match delivery.channel {
        Channel::Telegram => None,
        Channel::Blooio => Some(stable_idempotency_key(
            &delivery.uid,
            delivery.channel,
            &delivery.idempotency_key,
        )),
    };
    provider_send_request(
        env,
        delivery.channel,
        &delivery.channel_chat_id,
        &delivery.text,
        idempotency.as_deref(),
    )
}

/// Control-plane reply (link code, command output, unlink confirmation) that
/// bypasses `channel_deliveries` — parity with `sendChannelText`.
pub async fn send_channel_text(
    env: &Env,
    channel: Channel,
    chat_id: &str,
    text: &str,
) -> Result<bool> {
    let Some(request) = provider_send_request(env, channel, chat_id, text, None)? else {
        return Ok(false);
    };
    match Fetch::Request(request).send().await {
        Ok(response) => Ok((200..300).contains(&response.status_code())),
        Err(_) => Ok(false),
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

/// `dispatchChannelMessage` — route a due delivery through the per-uid/channel
/// DeliveryCoordinator's `/deliver` endpoint (best-effort; the caller maps a
/// failure to a 503, and the scheduled drain retries regardless).
pub async fn dispatch_channel_message(
    env: &Env,
    id: &str,
    uid: &str,
    channel: Channel,
) -> Result<()> {
    let now = now_ms();
    dispatch_to_coordinator(
        env,
        uid,
        channel,
        "/deliver",
        &json!({ "id": id, "uid": uid, "channel": channel.as_str(), "now": now }),
    )
    .await
}

/// `dispatchChannelUnlink` — route an unlink through the per-uid/channel
/// DeliveryCoordinator so it serializes with in-flight deliveries.
pub async fn dispatch_channel_unlink(env: &Env, uid: &str, channel: Channel) -> Result<()> {
    dispatch_to_coordinator(
        env,
        uid,
        channel,
        "/unlink",
        &json!({ "uid": uid, "channel": channel.as_str() }),
    )
    .await
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

async fn recent_history(env: &Env, uid: &str, channel: &str) -> Result<Vec<fallback::Message>> {
    let db = env.d1("DB")?;
    let rows = db
        .prepare(
            "SELECT role, text FROM conversation_messages\n       WHERE uid = ?1 AND conversation_id = ?1\n         AND cursor > COALESCE(\n           (SELECT MAX(conversation_reset_cursor) FROM channel_bindings\n            WHERE uid = ?1 AND channel = ?3 AND revoked_at IS NULL),\n           0)\n       ORDER BY cursor DESC LIMIT ?2",
        )
        .bind(&[
            uid.into(),
            (fallback::HISTORY_LIMIT as f64).into(),
            channel.into(),
        ])?
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
    let channel = json_str(&item, "channel").unwrap_or_default();
    let attempts = json_i64(&item, "attempts").unwrap_or(0) as u32;

    let mut reply = if env_has_active_pro(env, uid).await {
        let memory_context = memory_context_for(env, uid, &text).await;
        let history = recent_history(env, uid, &channel).await.unwrap_or_default();
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
