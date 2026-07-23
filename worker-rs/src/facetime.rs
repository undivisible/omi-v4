//! Pure parity port of `worker/src/facetime.ts`.
//!
//! Blooio's FaceTime bridge mints a shareable link, rings the handle over
//! FaceTime Audio and auto-admits the first joiner. A handle is either an
//! E.164 phone number or an email address; anything else is rejected here and
//! never forwarded, because the upstream call rings a real phone.

use serde_json::Value;

use crate::crypto_util::sha256_hex;

pub const FACETIME_ENDPOINT: &str = "https://api.blooio.com/v2/api/facetime/calls";
pub const UPSTREAM_TIMEOUT_MS: i64 = 15_000;
pub const HANDLE_MAX_CHARACTERS: usize = 254;

/// `phonePattern = /^\+[1-9]\d{6,14}$/`
fn is_e164(handle: &str) -> bool {
    let Some(rest) = handle.strip_prefix('+') else {
        return false;
    };
    let mut bytes = rest.bytes();
    match bytes.next() {
        Some(first) if (b'1'..=b'9').contains(&first) => {}
        _ => return false,
    }
    let tail = rest.len() - 1;
    (6..=14).contains(&tail) && rest.bytes().all(|b| b.is_ascii_digit())
}

/// `emailPattern = /^[^\s@]{1,64}@[^\s@.]+(?:\.[^\s@.]+)+$/`
fn is_email(handle: &str) -> bool {
    let Some((local, domain)) = handle.split_once('@') else {
        return false;
    };
    let local_length = local.chars().count();
    if !(1..=64).contains(&local_length) || local.chars().any(char::is_whitespace) {
        return false;
    }
    if domain.contains('@') {
        return false;
    }
    let labels: Vec<&str> = domain.split('.').collect();
    labels.len() >= 2
        && labels
            .iter()
            .all(|label| !label.is_empty() && !label.chars().any(char::is_whitespace))
}

/// `normalizeHandle` — trims, bounds, and lowercases an accepted email.
pub fn normalize_handle(value: Option<&Value>) -> Option<String> {
    let raw = value?.as_str()?;
    let handle = raw.trim();
    let length = handle.chars().count();
    if length == 0 || length > HANDLE_MAX_CHARACTERS {
        return None;
    }
    if is_e164(handle) {
        return Some(handle.to_string());
    }
    is_email(handle).then(|| handle.to_lowercase())
}

/// `idempotencyKey(uid, token)` — SHA-256 of `"<uid> facetime <token>"`, hex.
pub fn idempotency_key(uid: &str, token: &str) -> String {
    sha256_hex(&format!("{uid} facetime {token}"))
}

/// `FaceTimeOutcome`.
#[derive(Debug, PartialEq)]
pub enum FaceTimeOutcome {
    Ok {
        link: String,
        handle: String,
    },
    Unconfigured,
    /// Blooio answers 501: the route ships but is switched off. An expected
    /// product state, not a fault, and nothing is queued for retry.
    Unavailable,
    Rejected {
        status: u16,
    },
    Failed,
}

/// Maps an upstream status + body to an outcome. `status`/`body` are `None`
/// when the request itself threw, which is a plain failure.
pub fn outcome_for(status: u16, body: Option<&Value>, handle: &str) -> FaceTimeOutcome {
    if status == 501 {
        return FaceTimeOutcome::Unavailable;
    }
    if status == 400 || status == 422 {
        return FaceTimeOutcome::Rejected { status };
    }
    if !(200..300).contains(&status) {
        return FaceTimeOutcome::Failed;
    }
    let Some(body) = body else {
        return FaceTimeOutcome::Failed;
    };
    if body.get("success") != Some(&Value::Bool(true)) {
        return FaceTimeOutcome::Failed;
    }
    let link = match body.get("link").and_then(Value::as_str) {
        Some(link) if !link.is_empty() => link.to_string(),
        _ => return FaceTimeOutcome::Failed,
    };
    let handle = body
        .get("handle")
        .and_then(Value::as_str)
        .unwrap_or(handle)
        .to_string();
    FaceTimeOutcome::Ok { link, handle }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn handle(value: &str) -> Option<String> {
        normalize_handle(Some(&json!(value)))
    }

    #[test]
    fn accepts_e164_phone_numbers() {
        assert_eq!(handle("+15551234567").as_deref(), Some("+15551234567"));
        assert_eq!(handle("  +447700900123 ").as_deref(), Some("+447700900123"));
        // 7 digits after the leading one is the minimum.
        assert_eq!(handle("+12345678").as_deref(), Some("+12345678"));
    }

    #[test]
    fn accepts_and_lowercases_email_addresses() {
        assert_eq!(
            handle("Person@Example.COM").as_deref(),
            Some("person@example.com")
        );
        assert_eq!(
            handle("a.b@c.d.example").as_deref(),
            Some("a.b@c.d.example")
        );
    }

    #[test]
    fn rejects_anything_that_is_neither() {
        for candidate in [
            "",
            "   ",
            "+0123456789",
            "+1234",
            "+1234567890123456",
            "15551234567",
            "person@example",
            "person@@example.com",
            "per son@example.com",
            "@example.com",
            "person@.com",
            "person@example.",
        ] {
            assert!(handle(candidate).is_none(), "should reject {candidate:?}");
        }
        assert!(normalize_handle(Some(&json!(12))).is_none());
        assert!(normalize_handle(Some(&Value::Null)).is_none());
        assert!(normalize_handle(None).is_none());
        let long = format!("{}@example.com", "a".repeat(250));
        assert!(handle(&long).is_none());
    }

    #[test]
    fn derives_a_stable_idempotency_key_per_uid_and_token() {
        let a = idempotency_key("uid-1", "token");
        assert_eq!(a, idempotency_key("uid-1", "token"));
        assert_ne!(a, idempotency_key("uid-2", "token"));
        assert_ne!(a, idempotency_key("uid-1", "other"));
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn reports_the_disabled_upstream_distinctly_from_a_failure() {
        assert_eq!(
            outcome_for(501, None, "+15551234567"),
            FaceTimeOutcome::Unavailable
        );
        assert_eq!(
            outcome_for(400, None, "+15551234567"),
            FaceTimeOutcome::Rejected { status: 400 }
        );
        assert_eq!(
            outcome_for(422, None, "+15551234567"),
            FaceTimeOutcome::Rejected { status: 422 }
        );
        assert_eq!(
            outcome_for(500, None, "+15551234567"),
            FaceTimeOutcome::Failed
        );
        assert_eq!(
            outcome_for(200, None, "+15551234567"),
            FaceTimeOutcome::Failed
        );
    }

    #[test]
    fn returns_the_call_link_on_success() {
        assert_eq!(
            outcome_for(
                201,
                Some(&json!({ "success": true, "link": "https://facetime.apple.com/x" })),
                "+15551234567"
            ),
            FaceTimeOutcome::Ok {
                link: "https://facetime.apple.com/x".into(),
                handle: "+15551234567".into(),
            }
        );
        assert_eq!(
            outcome_for(
                200,
                Some(&json!({ "success": true, "link": "l", "handle": "+19998887777" })),
                "+15551234567"
            ),
            FaceTimeOutcome::Ok {
                link: "l".into(),
                handle: "+19998887777".into(),
            }
        );
    }

    #[test]
    fn an_untruthful_success_body_is_a_failure() {
        for body in [
            json!({ "success": false, "link": "l" }),
            json!({ "success": "true", "link": "l" }),
            json!({ "success": true, "link": "" }),
            json!({ "success": true }),
            json!({ "link": "l" }),
        ] {
            assert_eq!(
                outcome_for(200, Some(&body), "+15551234567"),
                FaceTimeOutcome::Failed,
                "should fail for {body}"
            );
        }
    }
}
