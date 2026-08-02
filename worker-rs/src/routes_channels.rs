//! workers-rs glue for the delivery group. Compiled only for wasm32.
//!
//! Behaviour parity with `worker/src/delivery.ts` and
//! `worker/src/inbox-fallback.ts`. The pure decision logic lives in
//! `crate::delivery` and `crate::inbox_fallback`; this file is the thin I/O
//! layer (Durable Object, D1, provider `fetch`) that drives them.

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::*;

use crate::billing;
use crate::byok_pricing;
use crate::channel_auth;
use crate::channel_checkout::{
    self, checkout_idempotency_key, checkout_reply, ChannelCheckout, CheckoutCompletion,
    EXPIRE_CHANNEL_CHECKOUT_SQL,
};
use crate::channel_commands as cmd;
use crate::channel_group::{self, GROUP_CHANNEL_LINK_ERROR};
use crate::channel_link;
use crate::channel_signup::{self, SignupResult, SIGNUP_GUIDE_TEXT};
use crate::delivery::{
    self, coordinator_name, due_deliveries_for_conversation_sql, due_deliveries_sql, http_outcome,
    network_error_message, network_outcome, retry_delay, stable_idempotency_key, Channel,
    RetryAfterHints, MAX_ATTEMPTS,
};
use crate::glue::error_json;
use crate::inbox_fallback as fallback;
use crate::stripe_sync::APPLY_SUBSCRIPTION_STATE_SQL;
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

async fn claim(
    db: &worker::D1Database,
    id: &str,
    now: i64,
    uid: &str,
    channel: Channel,
) -> Result<Option<DeliveryRow>> {
    let lease_token = random_uuid();
    let row = db
        .prepare(delivery::CLAIM_SQL)
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
        Channel::IMessage => {
            // Sendblue only — mirrors worker/src/delivery.ts providerRequest.
            let key_id = env
                .secret("SENDBLUE_API_KEY_ID")
                .ok()
                .map(|v| v.to_string())
                .or_else(|| env.var("SENDBLUE_API_KEY_ID").ok().map(|v| v.to_string()))
                .or_else(|| env.secret("SENDBLUE_API_KEY").ok().map(|v| v.to_string()))
                .or_else(|| env.var("SENDBLUE_API_KEY").ok().map(|v| v.to_string()))
                .filter(|v| !v.is_empty());
            let key_secret = env
                .secret("SENDBLUE_API_KEY_SECRET")
                .ok()
                .map(|v| v.to_string())
                .or_else(|| {
                    env.var("SENDBLUE_API_KEY_SECRET")
                        .ok()
                        .map(|v| v.to_string())
                })
                .or_else(|| {
                    env.secret("SENDBLUE_SECRET_KEY")
                        .ok()
                        .map(|v| v.to_string())
                })
                .or_else(|| env.var("SENDBLUE_SECRET_KEY").ok().map(|v| v.to_string()))
                .filter(|v| !v.is_empty());
            let from_number = env
                .secret("SENDBLUE_NUMBER")
                .ok()
                .map(|v| v.to_string())
                .or_else(|| env.var("SENDBLUE_NUMBER").ok().map(|v| v.to_string()))
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty());
            let (Some(key_id), Some(key_secret), Some(from_number)) =
                (key_id, key_secret, from_number)
            else {
                return Ok(None);
            };
            let mut init = RequestInit::new();
            init.with_method(Method::Post);
            let headers = Headers::new();
            headers.set("sb-api-key-id", &key_id)?;
            headers.set("sb-api-secret-key", &key_secret)?;
            headers.set("content-type", "application/json")?;
            let _ = idempotency_key; // Sendblue has no idempotency-key header.
            init.with_headers(headers);
            init.with_body(Some(JsValue::from_str(
                &json!({
                    "number": chat_id,
                    "from_number": from_number,
                    "content": text,
                })
                .to_string(),
            )));
            Ok(Some(Request::new_with_init(
                crate::sendblue::SEND_MESSAGE_ENDPOINT,
                &init,
            )?))
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
        Channel::IMessage => "SENDBLUE_WEBHOOK_SIGNING_SECRET",
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
    if crate::channel_group::is_group_channel_chat(
        channel.as_str(),
        channel_user_id,
        channel_chat_id,
    ) {
        return Ok(None);
    }
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

/// `issueSigninCode`: re-derive the outstanding sign-in code for a sender, or
/// mint a separate short-lived bearer code. It deliberately never reads or
/// writes `purpose = 'link'` rows.
pub async fn issue_signin_code(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<Option<(String, i64)>> {
    let Some(secret) = channel_webhook_secret(env, channel) else {
        return Ok(None);
    };
    if crate::channel_group::is_group_channel_chat(
        channel.as_str(),
        channel_user_id,
        channel_chat_id,
    ) {
        return Ok(None);
    }
    let db = env.d1("DB")?;
    let pending = db
        .prepare(
            "SELECT nonce, expires_at FROM channel_link_codes\n     WHERE channel = ?1 AND channel_user_id = ?2 AND purpose = ?3\n       AND consumed_at IS NULL AND expires_at > ?4\n     ORDER BY expires_at DESC LIMIT 1",
        )
        .bind(&[
            channel.as_str().into(),
            channel_user_id.into(),
            channel_auth::PURPOSE_SIGNIN.into(),
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

    // A seven-character code has a finite keyspace. Do not let a rare collision
    // overwrite (or inherit) a link code belonging to another sender.
    for _ in 0..4 {
        let nonce = random_uuid();
        let code =
            channel_link::derive_link_code(&secret, channel.as_str(), channel_user_id, &nonce);
        let expires_at = now + channel_auth::SIGNIN_CODE_TTL_MS;
        let inserted = db
            .prepare(
                "INSERT INTO channel_link_codes\n       (code_hash, channel, channel_user_id, channel_chat_id, nonce, expires_at, created_at, purpose)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)\n     ON CONFLICT(code_hash) DO NOTHING\n     RETURNING code_hash",
            )
            .bind(&[
                channel_link::code_hash(&code).into(),
                channel.as_str().into(),
                channel_user_id.into(),
                channel_chat_id.into(),
                nonce.into(),
                (expires_at as f64).into(),
                (now as f64).into(),
                channel_auth::PURPOSE_SIGNIN.into(),
            ])?
            .first::<Value>(None)
            .await?;
        if inserted.is_some() {
            return Ok(Some((code, expires_at)));
        }
    }
    Ok(None)
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
        Some("imessage") | Some("blooio") => Channel::IMessage,
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
    /// When this chat was last told what `/logout` will do. Repeating the whole
    /// explanation to someone who just read it is noise, not care.
    logout_prompted_at: Option<i64>,
}

async fn channel_binding(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
) -> Result<Option<ChannelBinding>> {
    let db = env.d1("DB")?;
    let row = db
        .prepare(
            "SELECT b.uid AS uid, b.verified_at AS verified_at,\n            b.logout_prompted_at AS logout_prompted_at, u.email AS email\n     FROM channel_bindings b LEFT JOIN users u ON u.uid = b.uid\n     WHERE b.channel = ?1 AND b.channel_user_id = ?2 AND b.revoked_at IS NULL",
        )
        .bind(&[channel.as_str().into(), channel_user_id.into()])?
        .first::<Value>(None)
        .await?;
    Ok(row.map(|row| ChannelBinding {
        uid: json_str(&row, "uid").unwrap_or_default(),
        verified_at: json_i64(&row, "verified_at").unwrap_or(0),
        email: json_str(&row, "email"),
        logout_prompted_at: json_i64(&row, "logout_prompted_at"),
    }))
}

/// How long a `/logout` explanation stands before it is worth repeating in
/// full. Long enough that sending the command a few times in a row gets the
/// short answer, short enough that coming back tomorrow gets the whole thing.
const LOGOUT_PROMPT_TTL_MS: i64 = 30 * 60 * 1000;

async fn remember_logout_prompt(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    now: i64,
) -> Result<()> {
    env.d1("DB")?
        .prepare(
            "UPDATE channel_bindings SET logout_prompted_at = ?1\n     WHERE channel = ?2 AND channel_user_id = ?3 AND revoked_at IS NULL",
        )
        .bind(&[now.into(), channel.as_str().into(), channel_user_id.into()])?
        .run()
        .await?;
    Ok(())
}

/// The ceiling on canned replies and link codes for a sender with no binding.
///
/// This is deliberately no longer a cap on *talking*. It used to be: five
/// messages an hour and then silence, applied to anyone who had not linked an
/// account, which is to say applied to everyone new. Conversation is unmetered
/// now — a new sender is given an account and answered on the cheap tier — and
/// what is left here guards only the two things worth guarding, link-code
/// issuance and the fixed command replies, in the narrow window where signup
/// did not produce a binding.
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

async fn checkout_allowed(env: &Env, channel: Channel, channel_user_id: &str) -> bool {
    let (per_sender, _) = crate::routes_ai::consume_rate_limit(
        env,
        &channel_checkout::checkout_rate_limit_key(channel.as_str(), channel_user_id),
        channel_checkout::CHECKOUT_PER_SENDER_LIMIT,
        channel_checkout::CHECKOUT_PER_SENDER_WINDOW_MS,
    )
    .await;
    if !per_sender {
        return false;
    }
    let (global, _) = crate::routes_ai::consume_rate_limit(
        env,
        channel_checkout::CHECKOUT_GLOBAL_RATE_LIMIT_KEY,
        channel_checkout::CHECKOUT_GLOBAL_LIMIT,
        channel_checkout::CHECKOUT_GLOBAL_WINDOW_MS,
    )
    .await;
    global
}

async fn signup_allowed(env: &Env, channel: Channel, channel_user_id: &str) -> bool {
    let (per_sender, _) = crate::routes_ai::consume_rate_limit(
        env,
        &channel_signup::signup_rate_limit_key(channel.as_str(), channel_user_id),
        channel_signup::SIGNUP_PER_SENDER_LIMIT,
        channel_signup::SIGNUP_PER_SENDER_WINDOW_MS,
    )
    .await;
    if !per_sender {
        return false;
    }
    let (global, _) = crate::routes_ai::consume_rate_limit(
        env,
        channel_signup::SIGNUP_GLOBAL_RATE_LIMIT_KEY,
        channel_signup::SIGNUP_GLOBAL_LIMIT,
        channel_signup::SIGNUP_GLOBAL_WINDOW_MS,
    )
    .await;
    global
}

fn env_var(env: &Env, name: &str) -> Option<String> {
    crate::worker_util::secret_or_var(env, name).filter(|v| !v.is_empty())
}

async fn byok_price_cents(env: &Env, uid: &str) -> Result<(i64, bool)> {
    let band = byok_pricing::price_band(|key| env_var(env, key));
    let db = env.d1("DB")?;
    let row = db
        .prepare("SELECT price_cents, outcome FROM byok_price_agreements WHERE uid = ?1")
        .bind(&[uid.into()])?
        .first::<Value>(None)
        .await?;
    let Some(row) = row else {
        return Ok((band.standard_cents, false));
    };
    let price_cents = json_i64(&row, "price_cents").unwrap_or(band.standard_cents);
    let outcome = json_str(&row, "outcome").unwrap_or_default();
    let price = band.standard_cents.min(band.floor_cents.max(price_cents));
    Ok((price, outcome == "negotiated"))
}

async fn stripe_post(
    secret: &str,
    path: &str,
    params: &[(String, String)],
    idempotency_key: Option<&str>,
) -> Result<Option<(String, String)>> {
    let url = Url::parse(&format!("https://api.stripe.com/v1/{path}"))
        .map_err(|e| worker::Error::RustError(e.to_string()))?;
    let headers = Headers::new();
    headers.set("authorization", &format!("Bearer {secret}"))?;
    headers.set("content-type", "application/x-www-form-urlencoded")?;
    headers.set("stripe-version", crate::stripe_sync::STRIPE_VERSION)?;
    if let Some(key) = idempotency_key {
        headers.set("idempotency-key", key)?;
    }
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(JsValue::from_str(&billing::encode_form(params))));
    let request = Request::new_with_init(url.as_str(), &init)?;
    let mut response = Fetch::Request(request).send().await?;
    let ok = (200..300).contains(&response.status_code());
    let body: Value = response.json().await.unwrap_or(Value::Null);
    Ok(billing::parse_session(ok, &body))
}

async fn stripe_price(secret: &str, price_id: &str) -> Option<(String, String, i64, String, i64)> {
    let url = format!(
        "https://api.stripe.com/v1/prices/{}",
        crate::stripe_sync::encode_path_segment(price_id)
    );
    let headers = Headers::new();
    headers
        .set("authorization", &format!("Bearer {secret}"))
        .ok()?;
    headers
        .set("stripe-version", crate::stripe_sync::STRIPE_VERSION)
        .ok()?;
    let mut init = RequestInit::new();
    init.with_method(Method::Get).with_headers(headers);
    let request = Request::new_with_init(&url, &init).ok()?;
    let mut response = Fetch::Request(request).send().await.ok()?;
    if !(200..300).contains(&response.status_code()) {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    let currency = body.get("currency").and_then(Value::as_str)?;
    let product = body.get("product").and_then(Value::as_str)?;
    let interval = body
        .get("recurring")
        .and_then(|r| r.get("interval"))
        .and_then(Value::as_str)?;
    let interval_count = body
        .get("recurring")
        .and_then(|r| r.get("interval_count"))
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(1)
        .max(1);
    let unit_amount = body
        .get("unit_amount")
        .and_then(|value| json_i64(value, "unit_amount"));
    Some((
        currency.to_string(),
        product.to_string(),
        unit_amount.unwrap_or(0),
        interval.to_string(),
        interval_count,
    ))
}

#[allow(clippy::too_many_arguments)]
async fn create_checkout_session(
    env: &Env,
    uid: &str,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    success_url: &str,
    cancel_url: &str,
    expires_at: i64,
    idempotency_key: &str,
) -> Result<Option<(String, String, i64)>> {
    let Some(secret) = env_var(env, "STRIPE_SECRET_KEY") else {
        return Ok(None);
    };
    let Some(price_id) = env_var(env, "STRIPE_PRO_PRICE_ID") else {
        return Ok(None);
    };
    let db = env.d1("DB")?;
    let entitlement = db
        .prepare("SELECT stripe_customer_id FROM entitlements WHERE uid = ?1")
        .bind(&[uid.into()])?
        .first::<Value>(None)
        .await?;
    let customer_id = entitlement
        .as_ref()
        .and_then(|row| json_str(row, "stripe_customer_id"));
    let (price_cents, negotiated) = byok_price_cents(env, uid).await?;
    let mut params = vec![
        ("mode".into(), "subscription".into()),
        ("line_items[0][quantity]".into(), "1".into()),
        ("client_reference_id".into(), uid.into()),
        ("metadata[firebase_uid]".into(), uid.into()),
        (
            "subscription_data[metadata][firebase_uid]".into(),
            uid.into(),
        ),
        ("metadata[channel]".into(), channel.as_str().into()),
        ("metadata[channel_user_id]".into(), channel_user_id.into()),
        ("metadata[channel_chat_id]".into(), channel_chat_id.into()),
        ("success_url".into(), success_url.into()),
        ("cancel_url".into(), cancel_url.into()),
        (
            "expires_at".into(),
            (expires_at.div_euclid(1_000)).to_string(),
        ),
        ("automatic_tax[enabled]".into(), "true".into()),
    ];
    if negotiated {
        if let Some((currency, product, unit_amount, interval, interval_count)) =
            stripe_price(&secret, &price_id).await
        {
            if unit_amount == price_cents {
                params.push(("line_items[0][price]".into(), price_id));
            } else {
                params.extend([
                    ("line_items[0][price_data][currency]".into(), currency),
                    ("line_items[0][price_data][product]".into(), product),
                    (
                        "line_items[0][price_data][unit_amount]".into(),
                        price_cents.to_string(),
                    ),
                    (
                        "line_items[0][price_data][recurring][interval]".into(),
                        interval,
                    ),
                    (
                        "line_items[0][price_data][recurring][interval_count]".into(),
                        interval_count.to_string(),
                    ),
                ]);
            }
        } else {
            return Ok(None);
        }
    } else {
        params.push(("line_items[0][price]".into(), price_id));
    }
    if let Some(customer_id) = customer_id {
        params.push(("customer".into(), customer_id));
        params.push(("customer_update[address]".into(), "auto".into()));
        params.push(("customer_update[name]".into(), "auto".into()));
    }
    let session = stripe_post(&secret, "checkout/sessions", &params, Some(idempotency_key)).await?;
    Ok(session.map(|(id, url)| (id, url, price_cents)))
}

/// `issueChannelCheckout`.
pub async fn issue_channel_checkout(
    env: &Env,
    uid: &str,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<ChannelCheckout> {
    let app_url = env_var(env, "APP_URL");
    let stripe_secret = env_var(env, "STRIPE_SECRET_KEY");
    let price_id = env_var(env, "STRIPE_PRO_PRICE_ID");
    if app_url.is_none() || stripe_secret.is_none() || price_id.is_none() {
        return Ok(ChannelCheckout::Unconfigured);
    }
    if env_has_active_pro(env, uid).await {
        return Ok(ChannelCheckout::Subscribed);
    }
    let db = env.d1("DB")?;
    let live = db
        .prepare(
            "SELECT url, price_cents FROM channel_checkout_sessions\n     WHERE uid = ?1 AND completed_at IS NULL AND expires_at > ?2\n     ORDER BY created_at DESC LIMIT 1",
        )
        .bind(&[uid.into(), (now as f64).into()])?
        .first::<Value>(None)
        .await?;
    if let Some(live) = live {
        return Ok(ChannelCheckout::Reused {
            url: json_str(&live, "url").unwrap_or_default(),
            price_cents: json_i64(&live, "price_cents").unwrap_or(0),
        });
    }
    if !checkout_allowed(env, channel, channel_user_id).await {
        return Ok(ChannelCheckout::RateLimited);
    }
    let expires_at = now + channel_checkout::CHECKOUT_TTL_MS;
    let app_url = app_url.unwrap_or_default();
    let idempotency_key = checkout_idempotency_key(channel.as_str(), channel_user_id, now);
    let Some((session_id, url, price_cents)) = create_checkout_session(
        env,
        uid,
        channel,
        channel_user_id,
        channel_chat_id,
        &format!("{app_url}/billing/success?session_id={{CHECKOUT_SESSION_ID}}"),
        &format!("{app_url}/billing"),
        expires_at,
        &idempotency_key,
    )
    .await?
    else {
        return Ok(ChannelCheckout::Unavailable);
    };
    db.prepare(
        "INSERT INTO channel_checkout_sessions\n       (session_id, uid, channel, channel_user_id, channel_chat_id,\n        price_cents, url, created_at, expires_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)\n     ON CONFLICT DO NOTHING",
    )
    .bind(&[
        session_id.into(),
        uid.into(),
        channel.as_str().into(),
        channel_user_id.into(),
        channel_chat_id.into(),
        (price_cents as f64).into(),
        url.clone().into(),
        (now as f64).into(),
        (expires_at as f64).into(),
    ])?
    .run()
    .await?;
    Ok(ChannelCheckout::Issued { url, price_cents })
}

/// `expireChannelCheckout`.
pub async fn expire_channel_checkout(env: &Env, session_id: &str, now: i64) -> Result<()> {
    let db = env.d1("DB")?;
    db.prepare(EXPIRE_CHANNEL_CHECKOUT_SQL)
        .bind(&[(now as f64).into(), session_id.into()])?
        .run()
        .await?;
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub struct CompleteChannelCheckoutResult {
    pub provisioned: bool,
    pub uid: Option<String>,
}

/// `completeChannelCheckout`.
pub async fn complete_channel_checkout(
    env: &Env,
    event: CheckoutCompletion,
    now: i64,
) -> Result<CompleteChannelCheckoutResult> {
    if !channel_checkout::checkout_prerequisites_met(&event) {
        return Ok(CompleteChannelCheckoutResult {
            provisioned: false,
            uid: None,
        });
    }
    let session_id = event.session_id.clone().unwrap_or_default();
    let event_uid = event.uid.clone().unwrap_or_default();
    let customer = event.customer.clone().unwrap_or_default();
    let db = env.d1("DB")?;
    let row = db
        .prepare(
            "SELECT uid, channel, channel_chat_id, price_cents\n     FROM channel_checkout_sessions\n     WHERE session_id = ?1 AND completed_at IS NULL",
        )
        .bind(&[session_id.clone().into()])?
        .first::<Value>(None)
        .await?;
    let Some(row) = row else {
        return Ok(CompleteChannelCheckoutResult {
            provisioned: false,
            uid: None,
        });
    };
    let row_uid = json_str(&row, "uid").unwrap_or_default();
    if !channel_checkout::session_uid_matches(&row_uid, &event_uid) {
        return Ok(CompleteChannelCheckoutResult {
            provisioned: false,
            uid: None,
        });
    }
    let account = db
        .prepare("SELECT claimed_by_uid, retired_at FROM channel_accounts WHERE uid = ?1")
        .bind(&[row_uid.clone().into()])?
        .first::<Value>(None)
        .await?;
    let claimed_by = account
        .as_ref()
        .and_then(|row| json_str(row, "claimed_by_uid"));
    let retired = account
        .as_ref()
        .and_then(|row| json_i64(row, "retired_at"))
        .is_some();
    let target = channel_checkout::completion_target_uid(&row_uid, claimed_by.as_deref());
    let channel = json_str(&row, "channel").unwrap_or_default();
    let channel_chat_id = json_str(&row, "channel_chat_id").unwrap_or_default();
    let price_cents = json_i64(&row, "price_cents").unwrap_or(0);
    let confirmation = channel_checkout::subscription_confirmation_message(
        price_cents,
        claimed_by.as_deref(),
        retired,
    );
    let audit_id = random_uuid();
    let audit_details = json!({
        "sessionId": session_id,
        "placeholderUid": row_uid,
        "priceCents": price_cents,
    })
    .to_string();
    let results = db
        .batch(vec![
            db.prepare(
                "UPDATE channel_checkout_sessions SET completed_at = ?1\n       WHERE session_id = ?2 AND completed_at IS NULL",
            )
            .bind(&[(now as f64).into(), session_id.clone().into()])?,
            db.prepare(APPLY_SUBSCRIPTION_STATE_SQL).bind(&[
                "active".into(),
                JsValue::NULL,
                customer.clone().into(),
                (now as f64).into(),
                js_opt(event.subscription.as_deref()),
                JsValue::NULL,
                (event.event_created as f64).into(),
                target.clone().into(),
            ])?,
            db.prepare(
                "UPDATE channel_accounts SET billing_email = ?1 WHERE uid = ?2 AND billing_email IS NULL",
            )
            .bind(&[js_opt(event.email.as_deref()), row_uid.clone().into()])?,
            db.prepare(
                "INSERT INTO audit_events\n         (id, uid, actor_type, action, target_type, target_id, details, created_at)\n       VALUES (?1, ?2, 'system', 'channel.subscription_activated', 'channel', ?3, ?4, ?5)",
            )
            .bind(&[
                audit_id.into(),
                target.clone().into(),
                channel.clone().into(),
                audit_details.into(),
                (now as f64).into(),
            ])?,
        ])
        .await?;
    let changes = results
        .first()
        .map(|r| r.meta().ok().flatten().and_then(|m| m.changes).unwrap_or(0))
        .unwrap_or(0);
    if changes != 1 {
        return Ok(CompleteChannelCheckoutResult {
            provisioned: false,
            uid: None,
        });
    }
    if let Some(channel) = Channel::parse(&channel) {
        let _ = send_channel_text(env, channel, &channel_chat_id, &confirmation).await;
    }
    Ok(CompleteChannelCheckoutResult {
        provisioned: true,
        uid: Some(target),
    })
}

fn js_opt(value: Option<&str>) -> JsValue {
    value.map(JsValue::from).unwrap_or(JsValue::NULL)
}

async fn is_channel_account(env: &Env, uid: &str) -> Result<bool> {
    let db = env.d1("DB")?;
    let row = db
        .prepare("SELECT uid FROM channel_accounts WHERE uid = ?1")
        .bind(&[uid.into()])?
        .first::<Value>(None)
        .await?;
    Ok(row.is_some())
}

/// `liveChannelAccount`.
pub async fn live_channel_account(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
) -> Result<Option<channel_signup::ChannelAccount>> {
    let db = env.d1("DB")?;
    let row = db
        .prepare(
            "SELECT uid, created_at, claimed_at FROM channel_accounts\n       WHERE channel = ?1 AND channel_user_id = ?2\n         AND claimed_at IS NULL AND retired_at IS NULL",
        )
        .bind(&[channel.as_str().into(), channel_user_id.into()])?
        .first::<Value>(None)
        .await?;
    Ok(row.map(|row| channel_signup::ChannelAccount {
        uid: json_str(&row, "uid").unwrap_or_default(),
        created_at: json_i64(&row, "created_at").unwrap_or(0),
        claimed_at: json_i64(&row, "claimed_at"),
    }))
}

fn channel_uid() -> String {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes).expect("getrandom");
    format!(
        "chan_{}",
        bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

/// `signUpChannelSender`.
pub async fn sign_up_channel_sender(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<SignupResult> {
    let existing_account = live_channel_account(env, channel, channel_user_id).await?;
    let db = env.d1("DB")?;
    let binding = db
        .prepare(
            "SELECT uid FROM channel_bindings\n     WHERE channel = ?1 AND channel_user_id = ?2 AND revoked_at IS NULL",
        )
        .bind(&[channel.as_str().into(), channel_user_id.into()])?
        .first::<Value>(None)
        .await?;
    if let Some(binding) = binding {
        let binding_uid = json_str(&binding, "uid").unwrap_or_default();
        return if existing_account
            .as_ref()
            .is_some_and(|a| a.uid == binding_uid)
        {
            Ok(SignupResult::Existing { uid: binding_uid })
        } else {
            Ok(SignupResult::Conflict)
        };
    }
    if let Some(existing_account) = existing_account {
        return Ok(SignupResult::Existing {
            uid: existing_account.uid,
        });
    }
    if !signup_allowed(env, channel, channel_user_id).await {
        return Ok(SignupResult::RateLimited);
    }
    let uid = channel_uid();
    let audit_id = random_uuid();
    let audit_details =
        json!({ "channelUserId": channel_user_id, "channelChatId": channel_chat_id }).to_string();
    let results = db
        .batch(vec![
            db.prepare(
                "INSERT INTO users (uid, email, created_at, updated_at) VALUES (?1, NULL, ?2, ?2)",
            )
            .bind(&[uid.clone().into(), (now as f64).into()])?,
            db.prepare(
                "INSERT INTO channel_accounts\n         (uid, channel, channel_user_id, channel_chat_id, created_at)\n       VALUES (?1, ?2, ?3, ?4, ?5)\n       ON CONFLICT DO NOTHING",
            )
            .bind(&[
                uid.clone().into(),
                channel.as_str().into(),
                channel_user_id.into(),
                channel_chat_id.into(),
                (now as f64).into(),
            ])?,
            db.prepare(
                "INSERT INTO channel_bindings\n         (channel, channel_user_id, uid, verified_at, revoked_at, channel_chat_id)\n       VALUES (?1, ?2, ?3, ?4, NULL, ?5)\n       ON CONFLICT(channel, channel_user_id) DO UPDATE SET\n         uid = excluded.uid, verified_at = excluded.verified_at,\n         revoked_at = NULL, channel_chat_id = excluded.channel_chat_id\n       WHERE channel_bindings.revoked_at IS NOT NULL",
            )
            .bind(&[
                channel.as_str().into(),
                channel_user_id.into(),
                uid.clone().into(),
                (now as f64).into(),
                channel_chat_id.into(),
            ])?,
            db.prepare(
                "INSERT INTO audit_events\n         (id, uid, actor_type, action, target_type, target_id, details, created_at)\n       VALUES (?1, ?2, 'channel', 'channel.account_created', 'channel', ?3, ?4, ?5)",
            )
            .bind(&[
                audit_id.into(),
                uid.clone().into(),
                channel.as_str().into(),
                audit_details.into(),
                (now as f64).into(),
            ])?,
        ])
        .await?;
    let account_changes = results
        .get(1)
        .map(|r| r.meta().ok().flatten().and_then(|m| m.changes).unwrap_or(0))
        .unwrap_or(0);
    let binding_changes = results
        .get(2)
        .map(|r| r.meta().ok().flatten().and_then(|m| m.changes).unwrap_or(0))
        .unwrap_or(0);
    if account_changes != 1 || binding_changes != 1 {
        db.prepare("DELETE FROM users WHERE uid = ?1")
            .bind(&[uid.into()])?
            .run()
            .await?;
        let settled = live_channel_account(env, channel, channel_user_id).await?;
        return Ok(if let Some(settled) = settled {
            SignupResult::Existing { uid: settled.uid }
        } else {
            SignupResult::Conflict
        });
    }
    Ok(SignupResult::Created { uid })
}

/// `claimChannelAccount`.
pub async fn claim_channel_account(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    claimed_by_uid: &str,
    now: i64,
) -> Result<Option<String>> {
    let account = live_channel_account(env, channel, channel_user_id).await?;
    let Some(account) = account else {
        return Ok(None);
    };
    let db = env.d1("DB")?;
    let result = db
        .prepare(
            "UPDATE channel_accounts SET claimed_at = ?1, claimed_by_uid = ?2\n       WHERE uid = ?3 AND claimed_at IS NULL AND retired_at IS NULL",
        )
        .bind(&[
            (now as f64).into(),
            claimed_by_uid.into(),
            account.uid.clone().into(),
        ])?
        .run()
        .await?;
    let changes = result
        .meta()
        .ok()
        .flatten()
        .and_then(|m| m.changes)
        .unwrap_or(0);
    Ok((changes == 1).then_some(account.uid))
}

async fn retire_channel_account(env: &Env, uid: &str, now: i64) -> Result<()> {
    let db = env.d1("DB")?;
    db.prepare("UPDATE channel_accounts SET retired_at = ?1 WHERE uid = ?2 AND retired_at IS NULL")
        .bind(&[(now as f64).into(), uid.into()])?
        .run()
        .await?;
    Ok(())
}

async fn offer_checkout(
    env: &Env,
    uid: &str,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<Option<String>> {
    let checkout =
        issue_channel_checkout(env, uid, channel, channel_user_id, channel_chat_id, now).await?;
    Ok(checkout_reply(&checkout))
}

fn signup_guide(channel: Channel, channel_user_id: &str, channel_chat_id: &str) -> ChannelOutcome {
    if channel_group::is_group_channel_chat(channel.as_str(), channel_user_id, channel_chat_id) {
        return ChannelOutcome {
            reply: Some(GROUP_CHANNEL_LINK_ERROR.to_string()),
            enqueue: false,
        };
    }
    ChannelOutcome {
        reply: Some(SIGNUP_GUIDE_TEXT.to_string()),
        enqueue: false,
    }
}

/// Someone we have never heard from, saying something that is not a command.
///
/// They used to be screened: a canned introduction, a yes/no about whether they
/// already had an account, a clarification when the answer did not parse, and
/// a rate limit of five of those an hour. Nobody got to talk to the assistant
/// until they had navigated it, which meant the first thing Omi ever did was
/// refuse to be useful.
///
/// Now they get an account — a real row in `users`, same as anyone's — and the
/// message goes straight to the assistant. That account is what makes the rest
/// honest: everything they say is remembered under it from the first word, and
/// a sign-in code redeemed later signs them into that same uid, so the memory
/// graph they built while unsigned-in is simply theirs. Nothing is merged
/// because nothing was ever kept somewhere else.
async fn unrecognized_sender(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<ChannelOutcome> {
    if channel_group::is_group_channel_chat(channel.as_str(), channel_user_id, channel_chat_id) {
        return Ok(ChannelOutcome {
            reply: Some(GROUP_CHANNEL_LINK_ERROR.to_string()),
            enqueue: false,
        });
    }
    match sign_up_channel_sender(env, channel, channel_user_id, channel_chat_id, now).await? {
        // The binding is written by the signup, so the enqueue that follows
        // this outcome resolves the new uid and the assistant answers as it
        // would for anyone else.
        SignupResult::Created { .. } | SignupResult::Existing { .. } => Ok(ChannelOutcome {
            reply: None,
            enqueue: true,
        }),
        // No account could be provisioned — the global signup ceiling, or a
        // binding that points somewhere else. Offer the linking route instead
        // of dropping them into silence.
        SignupResult::RateLimited | SignupResult::Conflict => {
            start_link(env, channel, channel_user_id, channel_chat_id, now).await
        }
    }
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

async fn start_signin(
    env: &Env,
    channel: Channel,
    channel_user_id: &str,
    channel_chat_id: &str,
    now: i64,
) -> Result<ChannelOutcome> {
    match issue_signin_code(env, channel, channel_user_id, channel_chat_id, now).await? {
        Some((code, _)) => Ok(ChannelOutcome {
            reply: Some(cmd::signin_code_text(&code)),
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
    // Asking in words is the documented route — the app tells people to ask Omi
    // for a sign-in code, not to type a slash command they have never seen.
    //
    // Ungated, including for a sender with no binding yet. A code is how you
    // get *into* Omi, so metering it turns a bad first minute into no account
    // at all; and there is nothing to meter anyway, since an outstanding code
    // is re-derived rather than reissued.
    if cmd::is_signin_request(text) {
        return start_signin(env, channel, channel_user_id, channel_chat_id, now).await;
    }
    let Some(parsed) = cmd::parse_command(text) else {
        return if binding.is_some() {
            Ok(ChannelOutcome {
                reply: None,
                enqueue: true,
            })
        } else {
            unrecognized_sender(env, channel, channel_user_id, channel_chat_id, now).await
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
    if command.name == "/signin" {
        return start_signin(env, channel, channel_user_id, channel_chat_id, now).await;
    }
    let Some(binding) = binding else {
        if command.name == "/signup" {
            return Ok(signup_guide(channel, channel_user_id, channel_chat_id));
        }
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
    let channel_account = binding.email.is_none() && is_channel_account(env, &binding.uid).await?;
    let reply = match command.name {
        "/help" => cmd::channel_help_text(),
        "/signup" => {
            if channel_account {
                "This chat was set up here before accounts moved to the app. Sign in on your phone or desktop, then send /start here to link this chat to that account.".to_string()
            } else {
                format!(
                    "This chat is already linked to {masked}. Send /help if you need anything else."
                )
            }
        }
        "/start" => format!(
            "This chat is already linked to {masked}. Just send me a message and I'll \
answer. /help lists what else I understand here."
        ),
        "/subscribe" => match offer_checkout(
            env,
            &binding.uid,
            channel,
            channel_user_id,
            channel_chat_id,
            now,
        )
        .await?
        {
            Some(text) => text,
            None => {
                return Ok(ChannelOutcome {
                    reply: None,
                    enqueue: false,
                });
            }
        },
        "/status" => {
            let day = cmd::iso_date(binding.verified_at);
            if channel_account {
                format!(
                    "This chat is your Omi account, set up here on {day}. Sign in on your phone or desktop and send /start to move it across."
                )
            } else {
                format!("Linked to {masked} since {day}. Send /logout to disconnect this chat.")
            }
        }
        "/whoami" => {
            if channel_account {
                "I'm answering as the account that lives in this chat — it was created here and has no email yet.".to_string()
            } else {
                format!("I'm answering as {masked} — the Omi account this chat is linked to.")
            }
        }
        "/reset" => {
            reset_conversation(env, channel, channel_user_id, &binding.uid).await?;
            "Fresh start — I've dropped the earlier conversation from this chat's context. \
Your account stays linked."
                .to_string()
        }
        _ => {
            if !parsed.argument.eq_ignore_ascii_case("confirm") {
                // Someone who just read what this does and sent it again needs
                // the one thing they have to type, not the explanation over.
                let repeated = binding
                    .logout_prompted_at
                    .is_some_and(|at| now.saturating_sub(at) < LOGOUT_PROMPT_TTL_MS);
                remember_logout_prompt(env, channel, channel_user_id, now).await?;
                if repeated {
                    "Still waiting on /logout confirm.".to_string()
                } else if channel_account {
                    "This chat is the account, so there's no separate login to sign out of. To keep what I know, sign in on your phone or desktop and send /start here first. Send /logout confirm to close it instead — I'll stop answering here and this account won't be handed to anyone else.".to_string()
                } else {
                    format!(
                        "Unlinking disconnects this chat from {masked}: I'll stop answering here until you link again. Send /logout confirm to go ahead."
                    )
                }
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
                    Ok(()) => {
                        if channel_account {
                            retire_channel_account(env, &binding.uid, now).await?;
                            "Closed. This chat no longer has an Omi account — send /signup if you ever want a fresh one, or /start to link an account you sign in to.".to_string()
                        } else {
                            "Unlinked. This chat is no longer connected to your Omi account — send /start whenever you want to link it again.".to_string()
                        }
                    }
                    Err(_) => "I couldn't unlink this chat just now. Try again in a moment, or unlink it from Omi's settings.".to_string(),
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
        Channel::IMessage => Some(stable_idempotency_key(
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
    let plain = crate::channel_style::sanitize_channel_reply(channel.as_str(), text);
    if plain.is_empty() {
        return Ok(false);
    }
    let Some(request) = provider_send_request(env, channel, chat_id, &plain, None)? else {
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
        .prepare(due_deliveries_sql())
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

/// The same dispatch pass as [`deliver_due_channel_messages`], narrowed to one
/// (uid, channel) and meant to be run from a request rather than from the cron.
///
/// The cron is the reason replies used to feel slow: `crons = ["* * * * *"]` is
/// Cloudflare's floor, so a reply that became due a moment after a tick sat
/// there for the rest of the minute with nothing wrong with it. Kicking this
/// from the inbound webhook — under `waitUntil`, so the provider still gets its
/// 200 immediately — collapses that wait to nothing in the common case.
///
/// It does not replace the cron. It cannot: a delivery that fails here goes
/// back to `retry` with a `next_attempt_at` minutes out, and nobody is holding
/// a request open that long. The sweep stays the safety net for exactly those,
/// and for anything queued while no webhook happened to arrive.
pub async fn deliver_due_channel_messages_for(
    env: &Env,
    uid: &str,
    channel: Channel,
) -> Result<()> {
    let now = now_ms();
    let db = env.d1("DB")?;
    let rows = db
        .prepare(due_deliveries_for_conversation_sql())
        .bind(&[
            (MAX_ATTEMPTS as f64).into(),
            (now as f64).into(),
            uid.into(),
            channel.as_str().into(),
        ])?
        .all()
        .await?;
    for row in rows.results::<Value>()? {
        let Some(id) = json_str(&row, "id") else {
            continue;
        };
        // Through the coordinator, never straight into `deliver_channel_message`:
        // the DO is what serializes this drain against the cron's, so the two
        // never sit in `CLAIM_SQL` at the same instant for the same user.
        let _ = dispatch_to_coordinator(
            env,
            uid,
            channel,
            "/deliver",
            &json!({ "id": id, "uid": uid, "channel": channel.as_str(), "now": now }),
        )
        .await;
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
    tier: crate::managed_ai::ModelTier,
) -> Option<String> {
    let managed: Vec<crate::managed_ai::Message> = messages
        .iter()
        .map(|m| crate::managed_ai::Message {
            role: m.role.clone(),
            content: m.content.clone(),
        })
        .collect();
    crate::routes_ai::run_managed_inbox_completion(env, uid, &managed, tier).await
}

/// Whether this uid belongs to an account that was created here, in a chat,
/// and has not yet been signed into on a phone or desktop.
///
/// This is the only thing separating a guest from anyone else. It is not a
/// permission check — a guest gets the same assistant, the same memory, and no
/// message cap. It picks the model tier and one paragraph of prompt, and it
/// stops being true the moment they redeem a sign-in code.
async fn is_unclaimed_channel_account(env: &Env, uid: &str) -> bool {
    let Ok(db) = env.d1("DB") else {
        return false;
    };
    let row = db
        .prepare(
            "SELECT uid FROM channel_accounts\n     WHERE uid = ?1 AND claimed_at IS NULL AND retired_at IS NULL",
        )
        .bind(&[uid.into()]);
    match row {
        Ok(statement) => statement
            .first::<Value>(None)
            .await
            .ok()
            .flatten()
            .is_some(),
        Err(_) => false,
    }
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
            ((now - claim_delay_ms(env)) as f64).into(),
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
        let guest = is_unclaimed_channel_account(env, uid).await;
        let memory_context = memory_context_for(env, uid, &text).await;
        let history = recent_history(env, uid, &channel).await.unwrap_or_default();
        let messages =
            fallback::build_messages(&channel, memory_context.as_deref(), &history, &text, guest);
        // A guest conversation is unmetered, so the cheap tier is what makes it
        // affordable. Someone who has signed in is paying for the good one.
        let tier = if guest {
            crate::managed_ai::ModelTier::Speed
        } else {
            crate::managed_ai::ModelTier::Balanced
        };
        match managed_inbox_completion(env, uid, &messages, tier).await {
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
                fallback::MODEL_UNAVAILABLE_TEXT.to_string()
            }
        }
    } else {
        // No plan, so no assistant to run — and no desktop that was ever going
        // to answer on its behalf. Say what is actually in the way.
        fallback::NO_PLAN_TEXT.to_string()
    };
    reply = fallback::finalize_reply(&channel, &reply);
    let result = complete_inbox_item_done(env, uid, id, &lease_token, &reply, now_ms()).await;
    if !result.ok {
        release_for_retry(env, id, uid, &lease_token, &result.error).await?;
    }
    Ok(())
}

/// How long an inbox item must sit before this Worker will claim it, read from
/// `CHANNEL_RESPONDER_CLAIM_DELAY_MS` (see `inbox_fallback::claim_delay_ms`).
/// Zero unless someone deliberately asks for a grace window.
fn claim_delay_ms(env: &Env) -> i64 {
    fallback::claim_delay_ms(
        crate::worker_util::secret_or_var(env, "CHANNEL_RESPONDER_CLAIM_DELAY_MS").as_deref(),
    )
}

/// `CHANNEL_FALLBACK_RESPONDER = "false"` still switches the responder off —
/// the kill switch outlives the name, and it is the only way to stop the Worker
/// answering without a redeploy.
fn responder_disabled(env: &Env) -> bool {
    fallback::responder_disabled(
        env.var("CHANNEL_FALLBACK_RESPONDER")
            .ok()
            .map(|v| v.to_string())
            .as_deref(),
    )
}

/// Answer this user's freshly-arrived messages and put the replies on the wire,
/// now, from inside the request that delivered them.
///
/// This is the whole point of the change: the assistant runs here, in the
/// cloud, against memory that is already synced here, so there is nothing to
/// wait for. The webhook has already returned its 200 by the time this runs —
/// the caller hands it to `waitUntil` — so a slow model costs the provider
/// nothing and cannot earn us a webhook retry.
///
/// Answering and delivering are one call because they are one user-visible
/// event: a reply that exists in `channel_deliveries` but has not been sent is,
/// to the person holding the phone, indistinguishable from no reply at all.
pub async fn answer_and_deliver_now(env: &Env, uid: &str, channel: Channel) -> Result<()> {
    if !responder_disabled(env) {
        let now = now_ms();
        let db = env.d1("DB")?;
        let items = db
            .prepare(fallback::claimable_items_for_uid_sql())
            .bind(&[
                (fallback::MAX_ATTEMPTS as f64).into(),
                ((now - claim_delay_ms(env)) as f64).into(),
                (fallback::MAX_ITEMS_PER_RUN as f64).into(),
                uid.into(),
            ])?
            .all()
            .await?;
        for row in items.results::<Value>()? {
            if let Some(id) = json_str(&row, "id") {
                // `respond_to_item` claims through the same fenced UPDATE the
                // cron uses, so if the sweep — or a desktop — took this item
                // first, this call finds nothing and returns without a word.
                let _ = respond_to_item(env, &id, uid, now).await;
            }
        }
    }
    deliver_due_channel_messages_for(env, uid, channel).await
}

/// `respondToStaleInboxItems`.
pub async fn respond_to_stale_inbox_items(env: &Env) -> Result<()> {
    if responder_disabled(env) {
        return Ok(());
    }
    let now = now_ms();
    let db = env.d1("DB")?;
    let stale = db
        .prepare(fallback::claimable_items_sql())
        .bind(&[
            (fallback::MAX_ATTEMPTS as f64).into(),
            ((now - claim_delay_ms(env)) as f64).into(),
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
    let enforce = crate::worker_util::secret_or_var(env, "CHANNEL_REQUIRE_PLAN");
    if !crate::entitlement::plan_enforced(enforce.as_deref()) {
        return true;
    }
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
