//! Pure conversation logic ported from `worker/src/conversations.ts`: the
//! message payload-hash (idempotency key), and the request-validation
//! predicates for append, inbox-complete, replay range, and cursor updates.
//! The lease/claim/complete SQL mechanics are issued from the wasm glue.

use serde_json::{json, Value};

use crate::crypto_util::sha256_hex;

/// Idempotency payload hash for a conversation message: SHA-256 hex over
/// `JSON.stringify([role, source, text, channelMessageId ?? null,
/// deliveryId ?? null])`.
pub fn payload_hash(
    role: &str,
    source: &str,
    text: &str,
    channel_message_id: Option<&str>,
    delivery_id: Option<&str>,
) -> String {
    let array = json!([
        role,
        source,
        text,
        channel_message_id.map(Value::from).unwrap_or(Value::Null),
        delivery_id.map(Value::from).unwrap_or(Value::Null),
    ]);
    sha256_hex(&array.to_string())
}

/// `clientMessageId` validity for POST /messages: 8..=128 chars matching
/// `^[A-Za-z0-9._:-]+$`.
pub fn valid_client_message_id(value: &str) -> bool {
    let len = value.len();
    (8..=128).contains(&len) && value.bytes().all(is_id_byte)
}

/// Cursor `clientId` validity: `^[A-Za-z0-9._:-]{8,128}$`.
pub fn valid_cursor_client_id(value: &str) -> bool {
    valid_client_message_id(value)
}

/// Lease-token validity: `^[A-Za-z0-9-]{8,128}$`.
pub fn valid_lease_token(value: &str) -> bool {
    let len = value.len();
    (8..=128).contains(&len)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn is_id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-')
}

/// Validate a POST /messages append body. Returns the trimmed text on success.
pub fn validate_append(
    client_message_id: &Value,
    role: &Value,
    source: &Value,
    text: &Value,
) -> Option<AppendInput> {
    let client_message_id = client_message_id.as_str()?;
    if !valid_client_message_id(client_message_id) {
        return None;
    }
    let role = role
        .as_str()
        .filter(|r| *r == "user" || *r == "assistant")?;
    let source = source
        .as_str()
        .filter(|s| matches!(*s, "app" | "web" | "desktop"))?;
    let text = text.as_str()?;
    let trimmed = text.trim();
    if trimmed.is_empty() || text.len() > 20_000 {
        return None;
    }
    Some(AppendInput {
        client_message_id: client_message_id.to_string(),
        role: role.to_string(),
        source: source.to_string(),
        text: trimmed.to_string(),
    })
}

#[derive(Debug, PartialEq, Eq)]
pub struct AppendInput {
    pub client_message_id: String,
    pub role: String,
    pub source: String,
    pub text: String,
}

/// Outcome of validating a POST /inbox/:id/complete body.
#[derive(Debug, PartialEq, Eq)]
pub enum InboxOutcome {
    Done {
        lease_token: String,
        reply: String,
    },
    Retry {
        lease_token: String,
        error: Option<String>,
    },
}

/// Validate the inbox-complete body. `None` → 400 "Invalid inbox outcome".
/// Mirrors the compound guard exactly, including the rule that a `retry`
/// outcome must not carry `responseText`.
pub fn validate_inbox_complete(body: &Value) -> Option<InboxOutcome> {
    let lease_token = body.get("leaseToken").and_then(Value::as_str)?;
    if !valid_lease_token(lease_token) {
        return None;
    }
    let outcome = body.get("outcome").and_then(Value::as_str)?;
    let response_text = body.get("responseText");
    let error = body.get("error");
    // error, when present, must be a string of length <= 1000.
    let error_str = match error {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.len() <= 1_000 => Some(s.clone()),
        Some(_) => return None,
    };
    match outcome {
        "done" => {
            let reply = response_text.and_then(Value::as_str)?;
            let trimmed = reply.trim();
            if trimmed.is_empty() || reply.len() > 4_096 {
                return None;
            }
            Some(InboxOutcome::Done {
                lease_token: lease_token.to_string(),
                reply: trimmed.to_string(),
            })
        }
        "retry" => {
            // responseText must be undefined for retry.
            if response_text.is_some() {
                return None;
            }
            Some(InboxOutcome::Retry {
                lease_token: lease_token.to_string(),
                error: error_str,
            })
        }
        _ => None,
    }
}

/// Validate the replay range query. `None` → 400. Defaults: after=0, limit=100.
pub fn validate_replay_range(after: i64, limit: i64) -> bool {
    (0..=9_007_199_254_740_991).contains(&after) && (1..=200).contains(&limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_hash_matches_stringify() {
        // Cross-checked against sha256(JSON.stringify([...])).
        let hash = payload_hash("user", "telegram", "hi", None, None);
        assert_eq!(hash, sha256_hex(r#"["user","telegram","hi",null,null]"#));
        let with_ids = payload_hash("assistant", "telegram", "reply", None, Some("d1"));
        assert_eq!(
            with_ids,
            sha256_hex(r#"["assistant","telegram","reply",null,"d1"]"#)
        );
    }

    #[test]
    fn client_message_id_bounds() {
        assert!(valid_client_message_id("abcd1234"));
        assert!(valid_client_message_id("a.b_c:d-e"));
        assert!(!valid_client_message_id("short"));
        assert!(!valid_client_message_id(&"a".repeat(129)));
        assert!(!valid_client_message_id("has space!"));
    }

    #[test]
    fn lease_token_pattern() {
        assert!(valid_lease_token("abc-1234"));
        assert!(!valid_lease_token("has.dot123"));
        assert!(!valid_lease_token("short"));
    }

    #[test]
    fn append_validation() {
        use serde_json::json;
        assert_eq!(
            validate_append(
                &json!("client-1x"),
                &json!("user"),
                &json!("app"),
                &json!("  hi ")
            ),
            Some(AppendInput {
                client_message_id: "client-1x".into(),
                role: "user".into(),
                source: "app".into(),
                text: "hi".into(),
            })
        );
        // Bad role.
        assert!(validate_append(
            &json!("client-1x"),
            &json!("bot"),
            &json!("app"),
            &json!("hi")
        )
        .is_none());
        // Bad source.
        assert!(validate_append(
            &json!("client-1x"),
            &json!("user"),
            &json!("telegram"),
            &json!("hi")
        )
        .is_none());
        // Blank text.
        assert!(validate_append(
            &json!("client-1x"),
            &json!("user"),
            &json!("app"),
            &json!("   ")
        )
        .is_none());
    }

    #[test]
    fn inbox_done_and_retry() {
        use serde_json::json;
        assert_eq!(
            validate_inbox_complete(
                &json!({"leaseToken": "abc-1234", "outcome": "done", "responseText": " hi "})
            ),
            Some(InboxOutcome::Done {
                lease_token: "abc-1234".into(),
                reply: "hi".into(),
            })
        );
        assert_eq!(
            validate_inbox_complete(
                &json!({"leaseToken": "abc-1234", "outcome": "retry", "error": "boom"})
            ),
            Some(InboxOutcome::Retry {
                lease_token: "abc-1234".into(),
                error: Some("boom".into()),
            })
        );
    }

    #[test]
    fn inbox_complete_rejections() {
        use serde_json::json;
        // retry must not carry responseText.
        assert!(validate_inbox_complete(
            &json!({"leaseToken": "abc-1234", "outcome": "retry", "responseText": "x"})
        )
        .is_none());
        // done must carry non-blank responseText.
        assert!(
            validate_inbox_complete(&json!({"leaseToken": "abc-1234", "outcome": "done"}))
                .is_none()
        );
        assert!(validate_inbox_complete(
            &json!({"leaseToken": "abc-1234", "outcome": "done", "responseText": "   "})
        )
        .is_none());
        // bad lease token.
        assert!(
            validate_inbox_complete(&json!({"leaseToken": "short", "outcome": "retry"})).is_none()
        );
        // bad outcome.
        assert!(
            validate_inbox_complete(&json!({"leaseToken": "abc-1234", "outcome": "skip"}))
                .is_none()
        );
        // oversized error.
        assert!(validate_inbox_complete(
            &json!({"leaseToken": "abc-1234", "outcome": "retry", "error": "x".repeat(1001)})
        )
        .is_none());
        // oversized reply.
        assert!(validate_inbox_complete(
            &json!({"leaseToken": "abc-1234", "outcome": "done", "responseText": "x".repeat(4097)})
        )
        .is_none());
    }

    #[test]
    fn replay_range_bounds() {
        assert!(validate_replay_range(0, 100));
        assert!(validate_replay_range(5, 200));
        assert!(!validate_replay_range(-1, 100));
        assert!(!validate_replay_range(0, 0));
        assert!(!validate_replay_range(0, 201));
    }
}
