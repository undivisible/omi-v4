//! Pure webhook logic ported from `worker/src/webhooks.ts`. The security-
//! critical pieces — timestamped-HMAC verification, link-token extraction,
//! provider payload validation, and Stripe event field extraction — live here
//! and are host-testable. The D1 statements (dedupe, bind, enqueue,
//! entitlement state machine) are issued from the wasm glue.

use serde_json::Value;

use crate::crypto_util::{constant_time_eq, hmac_sha256_hex};

pub const TOLERANCE_SECONDS: i64 = 300;
pub const MAX_TEXT_LEN: usize = 20_000;

/// Verify a Stripe/Blooio `t=…,v1=…` timestamped HMAC signature.
///
/// Parity with `verifyTimestampedSignature`: split on commas, find `t=`,
/// collect lowercased `v1=` values, require an all-digit safe-integer
/// timestamp and at least one signature, enforce the ±tolerance window, then
/// constant-time compare the recomputed HMAC against any well-formed
/// (`^[a-f0-9]{64}$`) supplied signature. `now_seconds` is unix seconds.
pub fn verify_timestamped_signature(
    raw_body: &str,
    header: &str,
    secret: &str,
    now_seconds: i64,
) -> bool {
    let parts: Vec<&str> = header.split(',').map(str::trim).collect();
    let timestamp = parts.iter().find_map(|part| part.strip_prefix("t="));
    let signatures: Vec<String> = parts
        .iter()
        .filter_map(|part| part.strip_prefix("v1="))
        .map(|s| s.to_ascii_lowercase())
        .collect();
    let Some(timestamp) = timestamp else {
        return false;
    };
    if timestamp.is_empty()
        || !timestamp.bytes().all(|b| b.is_ascii_digit())
        || signatures.is_empty()
    {
        return false;
    }
    // Number.isSafeInteger bound (2^53 - 1). Reject anything larger or
    // unparseable.
    let Ok(timestamp_seconds) = timestamp.parse::<i64>() else {
        return false;
    };
    if timestamp_seconds > 9_007_199_254_740_991 {
        return false;
    }
    let age = now_seconds - timestamp_seconds;
    if age.abs() > TOLERANCE_SECONDS {
        return false;
    }
    let expected = hmac_sha256_hex(secret, &format!("{timestamp}.{raw_body}"));
    signatures
        .iter()
        .any(|signature| is_hex64_lower(signature) && constant_time_eq(&expected, signature))
}

fn is_hex64_lower(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_hex48_lower(value: &str) -> bool {
    value.len() == 48
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Extract a 48-hex link token. For Telegram, matches
/// `^/start(?:@[A-Za-z0-9_]+)? ([a-f0-9]{48})$`; otherwise `^([a-f0-9]{48})$`.
pub fn link_token(text: &str, telegram: bool) -> Option<String> {
    if !telegram {
        return if is_hex48_lower(text) {
            Some(text.to_string())
        } else {
            None
        };
    }
    let rest = text.strip_prefix("/start")?;
    // Optional @<username> where username is [A-Za-z0-9_]+ (at least one char).
    let rest = if let Some(after_at) = rest.strip_prefix('@') {
        let name_len = after_at
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
            .count();
        if name_len == 0 {
            return None;
        }
        &after_at[name_len..]
    } else {
        rest
    };
    // Exactly one separating space, then the token to end-of-string.
    let token = rest.strip_prefix(' ')?;
    if is_hex48_lower(token) {
        Some(token.to_string())
    } else {
        None
    }
}

/// A validated inbound Telegram message ready to link or enqueue.
#[derive(Debug, PartialEq, Eq)]
pub struct TelegramMessage {
    pub message_id: String,
    pub user_id: String,
    pub chat_id: String,
    pub text: String,
}

/// Parse+validate a Telegram update body. Returns `Err(())` when `update_id`
/// is not a safe integer (→ 400). `Ok((event_id, None))` means the update is
/// recorded but not actionable (blank/oversized/non-message → queued:false).
#[allow(clippy::result_unit_err)]
pub fn parse_telegram(body: &Value) -> Result<(String, Option<TelegramMessage>), ()> {
    let update_id = safe_integer(body.get("update_id")).ok_or(())?;
    let event_id = update_id.to_string();
    let message = body.get("message");
    let message_id = message
        .and_then(|m| m.get("message_id"))
        .and_then(safe_integer_ref);
    let from_id = message
        .and_then(|m| m.get("from"))
        .and_then(|f| f.get("id"))
        .and_then(safe_integer_ref);
    let chat_id = message
        .and_then(|m| m.get("chat"))
        .and_then(|c| c.get("id"))
        .and_then(safe_integer_ref);
    let text = message.and_then(|m| m.get("text")).and_then(Value::as_str);
    let (Some(message_id), Some(from_id), Some(chat_id), Some(text)) =
        (message_id, from_id, chat_id, text)
    else {
        return Ok((event_id, None));
    };
    let trimmed = text.trim();
    if trimmed.is_empty() || text.len() > MAX_TEXT_LEN {
        return Ok((event_id, None));
    }
    Ok((
        event_id,
        Some(TelegramMessage {
            message_id: message_id.to_string(),
            user_id: from_id.to_string(),
            chat_id: chat_id.to_string(),
            text: trimmed.to_string(),
        }),
    ))
}

/// A validated inbound Blooio message.
#[derive(Debug, PartialEq, Eq)]
pub struct BlooioMessage {
    pub event_id: String,
    pub message_id: String,
    pub sender: String,
    pub chat_id: String,
    pub text: String,
}

/// Validate a parsed Blooio event body. `None` → not actionable (queued:false).
pub fn parse_blooio(body: &Value) -> Option<BlooioMessage> {
    if body.get("event").and_then(Value::as_str) != Some("message.received") {
        return None;
    }
    let message_id = body.get("message_id").and_then(Value::as_str)?;
    let external_id = body.get("external_id").and_then(Value::as_str)?;
    let sender = body.get("sender").and_then(Value::as_str)?;
    let text = body.get("text").and_then(Value::as_str)?;
    let trimmed = text.trim();
    if trimmed.is_empty() || text.len() > MAX_TEXT_LEN {
        return None;
    }
    let is_group = body.get("is_group").and_then(Value::as_bool) == Some(true);
    let group_id = body.get("group_id").and_then(Value::as_str);
    let chat_id = match (is_group, group_id) {
        (true, Some(group_id)) => group_id,
        _ => external_id,
    };
    Some(BlooioMessage {
        event_id: format!("message.received:{message_id}"),
        message_id: message_id.to_string(),
        sender: sender.to_string(),
        chat_id: chat_id.to_string(),
        text: trimmed.to_string(),
    })
}

/// Outcome classes for a validated Stripe event, mirroring the branch order of
/// the `/stripe` handler. Field extraction is pure; the SQL execution is glue.
#[derive(Debug, PartialEq)]
pub enum StripePlan {
    /// No `data.object`, or missing uid/customer, or a non-subscription/
    /// non-checkout event: only the receipt row is written. `has_object`
    /// distinguishes the no-object branch (TS omits `updated`) from the
    /// object-present-but-unactionable branch (TS includes `updated: false`).
    ReceiptOnly { has_object: bool },
    /// `checkout.session.completed` with uid+customer: seed byok/inactive row.
    Checkout { uid: String, customer: String },
    /// A `customer.subscription.*` event with uid+customer.
    Subscription(StripeSubscription),
}

#[derive(Debug, PartialEq)]
pub struct StripeSubscription {
    pub uid: String,
    pub customer: String,
    pub subscription: Option<String>,
    pub active: bool,
    pub valid_until: Option<i64>,
    pub price_id: Option<String>,
    pub event_created: i64,
}

/// Validated top-level Stripe envelope.
pub struct StripeEnvelope {
    pub id: String,
    pub event_type: String,
    pub created: i64,
    pub plan: StripePlan,
}

/// Parse+classify a Stripe event body. `Err(())` → 400 (bad envelope).
#[allow(clippy::result_unit_err)]
pub fn parse_stripe(event: &Value) -> Result<StripeEnvelope, ()> {
    let id = event.get("id").and_then(Value::as_str).ok_or(())?;
    let event_type = event.get("type").and_then(Value::as_str).ok_or(())?;
    let created = safe_integer(event.get("created")).ok_or(())?;

    let object = event.get("data").and_then(|d| d.get("object"));
    let Some(object) = object.filter(|o| o.is_object()) else {
        return Ok(StripeEnvelope {
            id: id.to_string(),
            event_type: event_type.to_string(),
            created,
            plan: StripePlan::ReceiptOnly { has_object: false },
        });
    };

    let metadata = object.get("metadata").filter(|m| m.is_object());
    let uid = object
        .get("client_reference_id")
        .and_then(Value::as_str)
        .or_else(|| {
            metadata
                .and_then(|m| m.get("firebase_uid"))
                .and_then(Value::as_str)
        });
    let customer = object.get("customer").and_then(Value::as_str);
    let subscription = object
        .get("subscription")
        .and_then(Value::as_str)
        .map(String::from)
        .or_else(|| {
            let id_field = object.get("id").and_then(Value::as_str);
            if event_type.starts_with("customer.subscription.") {
                id_field.map(String::from)
            } else {
                None
            }
        });

    let (Some(uid), Some(customer)) = (uid, customer) else {
        return Ok(StripeEnvelope {
            id: id.to_string(),
            event_type: event_type.to_string(),
            created,
            plan: StripePlan::ReceiptOnly { has_object: true },
        });
    };

    if event_type == "checkout.session.completed" {
        return Ok(StripeEnvelope {
            id: id.to_string(),
            event_type: event_type.to_string(),
            created,
            plan: StripePlan::Checkout {
                uid: uid.to_string(),
                customer: customer.to_string(),
            },
        });
    }
    if !event_type.starts_with("customer.subscription.") {
        return Ok(StripeEnvelope {
            id: id.to_string(),
            event_type: event_type.to_string(),
            created,
            plan: StripePlan::ReceiptOnly { has_object: true },
        });
    }

    let status = object.get("status").and_then(Value::as_str);
    let active = status == Some("active") || status == Some("trialing");
    let valid_until = safe_integer(object.get("current_period_end")).map(|s| s * 1_000);
    let price_id = object
        .get("items")
        .and_then(|i| i.get("data"))
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|first| first.get("price"))
        .and_then(|p| p.get("id"))
        .and_then(Value::as_str)
        .map(String::from);

    Ok(StripeEnvelope {
        id: id.to_string(),
        event_type: event_type.to_string(),
        created,
        plan: StripePlan::Subscription(StripeSubscription {
            uid: uid.to_string(),
            customer: customer.to_string(),
            subscription,
            active,
            valid_until,
            price_id,
            event_created: created,
        }),
    })
}

/// `Number.isSafeInteger` semantics over a JSON number.
fn safe_integer(value: Option<&Value>) -> Option<i64> {
    safe_integer_ref(value?)
}

fn safe_integer_ref(value: &Value) -> Option<i64> {
    let number = value.as_f64()?;
    if number.fract() != 0.0 || number.abs() > 9_007_199_254_740_991.0 {
        return None;
    }
    Some(number as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sign(secret: &str, timestamp: i64, body: &str) -> String {
        let mac = hmac_sha256_hex(secret, &format!("{timestamp}.{body}"));
        format!("t={timestamp},v1={mac}")
    }

    #[test]
    fn accepts_valid_timestamped_signature() {
        let now = 1_700_000_000i64;
        let body = "{\"event\":\"message.received\"}";
        let header = sign("whsec_test", now, body);
        assert!(verify_timestamped_signature(
            body,
            &header,
            "whsec_test",
            now
        ));
    }

    #[test]
    fn rejects_signature_outside_tolerance() {
        let now = 1_700_000_000i64;
        let body = "{}";
        let header = sign("whsec_test", now - 301, body);
        assert!(!verify_timestamped_signature(
            body,
            &header,
            "whsec_test",
            now
        ));
        let future = sign("whsec_test", now + 301, body);
        assert!(!verify_timestamped_signature(
            body,
            &future,
            "whsec_test",
            now
        ));
    }

    #[test]
    fn rejects_wrong_secret_and_tampered_body() {
        let now = 1_700_000_000i64;
        let header = sign("whsec_test", now, "{}");
        assert!(!verify_timestamped_signature("{}", &header, "other", now));
        assert!(!verify_timestamped_signature(
            "{\"x\":1}",
            &header,
            "whsec_test",
            now
        ));
    }

    #[test]
    fn rejects_malformed_headers() {
        let now = 1_700_000_000i64;
        assert!(!verify_timestamped_signature("{}", "", "s", now));
        assert!(!verify_timestamped_signature(
            "{}",
            "t=abc,v1=deadbeef",
            "s",
            now
        ));
        assert!(!verify_timestamped_signature(
            "{}",
            &format!("t={now}"),
            "s",
            now
        ));
        // v1 present but not 64-hex.
        assert!(!verify_timestamped_signature(
            "{}",
            &format!("t={now},v1=zz"),
            "s",
            now
        ));
    }

    #[test]
    fn accepts_multiple_v1_signatures() {
        let now = 1_700_000_000i64;
        let good = hmac_sha256_hex("whsec_test", &format!("{now}.{{}}"));
        let header = format!("t={now},v1={},v1={good}", "0".repeat(64));
        assert!(verify_timestamped_signature(
            "{}",
            &header,
            "whsec_test",
            now
        ));
    }

    #[test]
    fn telegram_link_token_patterns() {
        let tok = "a".repeat(48);
        assert_eq!(
            link_token(&format!("/start {tok}"), true),
            Some(tok.clone())
        );
        assert_eq!(
            link_token(&format!("/start@my_bot {tok}"), true),
            Some(tok.clone())
        );
        assert_eq!(link_token(&format!("/start@ {tok}"), true), None);
        assert_eq!(link_token(&format!("/start  {tok}"), true), None);
        assert_eq!(link_token(&tok, true), None);
        assert_eq!(link_token("/start deadbeef", true), None);
        // Uppercase hex is rejected (regex is lowercase-only).
        assert_eq!(
            link_token(&format!("/start {}", "A".repeat(48)), true),
            None
        );
    }

    #[test]
    fn blooio_link_token_patterns() {
        let tok = "f".repeat(48);
        assert_eq!(link_token(&tok, false), Some(tok.clone()));
        assert_eq!(link_token(&format!("/start {tok}"), false), None);
        assert_eq!(link_token(&"f".repeat(47), false), None);
    }

    #[test]
    fn telegram_parse_valid_and_blank() {
        let body = json!({
            "update_id": 2,
            "message": {"message_id": 11, "text": "  hi  ", "from": {"id": 42}, "chat": {"id": 43}}
        });
        let (event_id, msg) = parse_telegram(&body).unwrap();
        assert_eq!(event_id, "2");
        assert_eq!(
            msg,
            Some(TelegramMessage {
                message_id: "11".into(),
                user_id: "42".into(),
                chat_id: "43".into(),
                text: "hi".into(),
            })
        );
        let blank = json!({
            "update_id": 3,
            "message": {"message_id": 1, "text": "   ", "from": {"id": 42}, "chat": {"id": 43}}
        });
        assert_eq!(parse_telegram(&blank).unwrap().1, None);
    }

    #[test]
    fn telegram_parse_rejects_bad_update_id() {
        assert!(parse_telegram(&json!({"update_id": 1.5})).is_err());
        assert!(parse_telegram(&json!({"update_id": "x"})).is_err());
        assert!(parse_telegram(&json!({})).is_err());
    }

    #[test]
    fn blooio_parse_group_and_direct() {
        let direct = json!({
            "event": "message.received", "message_id": "m1",
            "external_id": "+1555", "sender": "+1555", "text": "Remember this", "is_group": false
        });
        let parsed = parse_blooio(&direct).unwrap();
        assert_eq!(parsed.event_id, "message.received:m1");
        assert_eq!(parsed.chat_id, "+1555");
        let group = json!({
            "event": "message.received", "message_id": "m2",
            "external_id": "+1555", "sender": "+1555", "text": "hi",
            "is_group": true, "group_id": "g99"
        });
        assert_eq!(parse_blooio(&group).unwrap().chat_id, "g99");
    }

    #[test]
    fn blooio_parse_rejects_blank_and_oversized() {
        let blank = json!({
            "event": "message.received", "message_id": "m", "external_id": "e",
            "sender": "s", "text": "\n\t", "is_group": false
        });
        assert!(parse_blooio(&blank).is_none());
        let oversized = json!({
            "event": "message.received", "message_id": "m", "external_id": "e",
            "sender": "s", "text": "x".repeat(20_001), "is_group": false
        });
        assert!(parse_blooio(&oversized).is_none());
        let wrong_event = json!({"event": "message.sent", "message_id": "m"});
        assert!(parse_blooio(&wrong_event).is_none());
    }

    #[test]
    fn stripe_subscription_extraction() {
        let created = 1_700_000_000i64;
        let event = json!({
            "id": "evt_1", "type": "customer.subscription.updated", "created": created,
            "data": {"object": {
                "id": "sub_123", "customer": "cus_123", "status": "active",
                "current_period_end": created + 3600,
                "metadata": {"firebase_uid": "alpha"},
                "items": {"data": [{"price": {"id": "price_pro"}}]}
            }}
        });
        let env = parse_stripe(&event).unwrap();
        assert_eq!(env.id, "evt_1");
        match env.plan {
            StripePlan::Subscription(sub) => {
                assert_eq!(sub.uid, "alpha");
                assert_eq!(sub.customer, "cus_123");
                assert_eq!(sub.subscription.as_deref(), Some("sub_123"));
                assert!(sub.active);
                assert_eq!(sub.valid_until, Some((created + 3600) * 1000));
                assert_eq!(sub.price_id.as_deref(), Some("price_pro"));
                assert_eq!(sub.event_created, created);
            }
            other => panic!("expected subscription, got {other:?}"),
        }
    }

    #[test]
    fn stripe_checkout_and_client_reference_id() {
        let event = json!({
            "id": "evt_c", "type": "checkout.session.completed", "created": 10,
            "data": {"object": {"client_reference_id": "beta", "customer": "cus_9"}}
        });
        match parse_stripe(&event).unwrap().plan {
            StripePlan::Checkout { uid, customer } => {
                assert_eq!(uid, "beta");
                assert_eq!(customer, "cus_9");
            }
            other => panic!("expected checkout, got {other:?}"),
        }
    }

    #[test]
    fn stripe_receipt_only_paths() {
        // No data.object → TS omits `updated`.
        let no_object = json!({"id": "e", "type": "invoice.paid", "created": 1});
        assert_eq!(
            parse_stripe(&no_object).unwrap().plan,
            StripePlan::ReceiptOnly { has_object: false }
        );
        // Missing customer → object present, TS includes `updated: false`.
        let no_customer = json!({
            "id": "e", "type": "checkout.session.completed", "created": 1,
            "data": {"object": {"client_reference_id": "u"}}
        });
        assert_eq!(
            parse_stripe(&no_customer).unwrap().plan,
            StripePlan::ReceiptOnly { has_object: true }
        );
        // Non-subscription, non-checkout with uid+customer.
        let other = json!({
            "id": "e", "type": "invoice.paid", "created": 1,
            "data": {"object": {"client_reference_id": "u", "customer": "c"}}
        });
        assert_eq!(
            parse_stripe(&other).unwrap().plan,
            StripePlan::ReceiptOnly { has_object: true }
        );
    }

    #[test]
    fn stripe_rejects_bad_envelope() {
        assert!(parse_stripe(&json!({"type": "x", "created": 1})).is_err());
        assert!(parse_stripe(&json!({"id": "e", "created": 1})).is_err());
        assert!(parse_stripe(&json!({"id": "e", "type": "x", "created": 1.2})).is_err());
    }

    #[test]
    fn stripe_inactive_status() {
        let event = json!({
            "id": "e", "type": "customer.subscription.deleted", "created": 5,
            "data": {"object": {"id": "sub", "customer": "c", "status": "canceled",
                                 "metadata": {"firebase_uid": "u"}}}
        });
        match parse_stripe(&event).unwrap().plan {
            StripePlan::Subscription(sub) => {
                assert!(!sub.active);
                assert_eq!(sub.valid_until, None);
                assert_eq!(sub.price_id, None);
            }
            other => panic!("got {other:?}"),
        }
    }
}
