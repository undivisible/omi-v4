//! Pure parity port of `worker/src/sendblue.ts`.
//!
//! Sendblue is the iMessage/SMS/RCS provider. The stored channel identifier is
//! `"imessage"` (renamed from the historical `"blooio"` wire value).

use serde_json::{json, Value};

use crate::crypto_util::constant_time_eq;

pub const SEND_MESSAGE_ENDPOINT: &str = "https://api.sendblue.com/api/send-message";
pub const UPSTREAM_TIMEOUT_MS: i64 = 15_000;

/// The channel literal every stored row still uses.
pub const IMESSAGE_CHANNEL: &str = "imessage";

fn setting(env: &impl Fn(&str) -> Option<String>, name: &str) -> Option<String> {
    env(name)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// `grab-sendblue-secrets.sh` writes SENDBLUE_API_KEY / SENDBLUE_SECRET_KEY from
/// the Sendblue CLI; the worker headers use the _ID / _SECRET names. Accept both.
pub fn sendblue_api_key_id(env: &impl Fn(&str) -> Option<String>) -> String {
    env("SENDBLUE_API_KEY_ID")
        .or_else(|| env("SENDBLUE_API_KEY"))
        .unwrap_or_default()
        .trim()
        .to_string()
}

pub fn sendblue_api_key_secret(env: &impl Fn(&str) -> Option<String>) -> String {
    env("SENDBLUE_API_KEY_SECRET")
        .or_else(|| env("SENDBLUE_SECRET_KEY"))
        .unwrap_or_default()
        .trim()
        .to_string()
}

pub fn sendblue_configured(env: impl Fn(&str) -> Option<String>) -> bool {
    !sendblue_api_key_id(&env).is_empty()
        && !sendblue_api_key_secret(&env).is_empty()
        && setting(&env, "SENDBLUE_NUMBER").is_some()
}

pub fn sendblue_headers(env: impl Fn(&str) -> Option<String>) -> Vec<(String, String)> {
    vec![
        ("sb-api-key-id".into(), sendblue_api_key_id(&env)),
        ("sb-api-secret-key".into(), sendblue_api_key_secret(&env)),
        ("content-type".into(), "application/json".into()),
    ]
}

/// Sendblue's send endpoint has no idempotency key. The delivery queue's lease
/// and status machinery is therefore the only thing preventing a duplicate send
/// on retry — see `delivery`. Callers must not retry blindly.
pub fn sendblue_payload(
    env: impl Fn(&str) -> Option<String>,
    recipient: &str,
    text: &str,
) -> Value {
    json!({
        "number": recipient,
        "from_number": env("SENDBLUE_NUMBER").unwrap_or_default().trim(),
        "content": text,
    })
}

/// Sendblue does not sign webhook bodies. It echoes the shared secret that was
/// configured for the endpoint back in an `sb-signing-secret` header — there is
/// no HMAC, no timestamp, and therefore no binding between the secret and the
/// payload and no replay window. This is materially weaker than HMAC-signed
/// Stripe webhooks and cannot be fixed from our side, so it is compensated for:
///
///   1. The comparison below is constant-time, so the secret cannot be
///      recovered by timing the endpoint.
///   2. The webhook path itself carries a second high-entropy segment
///      (`SENDBLUE_WEBHOOK_PATH_TOKEN`), so knowing the header alone is not
///      enough to reach the route. Both must leak together.
///   3. Replay is bounded by `webhook_events`, keyed on the message handle, so
///      a captured request cannot be replayed into a second inbound message.
///
/// Rotate the secret through the Sendblue webhooks API on any suspicion of
/// exposure; unlike an HMAC scheme, an observed header is a permanent forgery
/// capability until it is rotated.
pub fn verify_sendblue_webhook(
    env: impl Fn(&str) -> Option<String>,
    path_token: &str,
    header: Option<&str>,
) -> bool {
    let (Some(secret), Some(expected_path_token)) = (
        setting(&env, "SENDBLUE_WEBHOOK_SIGNING_SECRET"),
        setting(&env, "SENDBLUE_WEBHOOK_PATH_TOKEN"),
    ) else {
        return false;
    };
    // Both gates are required and both are compared in constant time.
    let path_ok = constant_time_eq(path_token, &expected_path_token);
    let secret_ok = constant_time_eq(header.unwrap_or(""), &secret);
    path_ok && secret_ok
}

#[derive(Clone, Debug, PartialEq)]
pub struct SendblueInbound {
    pub message_handle: String,
    pub sender: String,
    pub chat_id: String,
    pub text: String,
    pub media_url: Option<String>,
}

/// The `receive` webhook payload. `from_number` is the end user, `number` is
/// the same value, `to_number` is our Sendblue line. Group messages carry a
/// non-empty `group_id`, which becomes the chat id so a group conversation
/// stays one thread.
pub fn parse_sendblue_inbound(body: &Value) -> Option<SendblueInbound> {
    let event = body.as_object()?;
    if event.get("is_outbound") == Some(&Value::Bool(true)) {
        return None;
    }
    let message_handle = event.get("message_handle")?.as_str()?;
    if message_handle.is_empty() {
        return None;
    }
    let sender = event.get("from_number")?.as_str()?;
    if sender.is_empty() || sender.chars().count() > 254 {
        return None;
    }
    let content = event
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let media_url = event
        .get("media_url")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    if content.is_empty() && media_url.is_none() {
        return None;
    }
    if content.chars().count() > 20_000 {
        return None;
    }
    let group_id = event.get("group_id").and_then(Value::as_str).unwrap_or("");
    Some(SendblueInbound {
        message_handle: message_handle.to_string(),
        chat_id: if group_id.is_empty() {
            sender.to_string()
        } else {
            group_id.to_string()
        },
        sender: sender.to_string(),
        text: content.to_string(),
        media_url,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name: &str| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| (*value).to_string())
        }
    }

    #[test]
    fn both_webhook_gates_are_required() {
        let configured = [
            ("SENDBLUE_WEBHOOK_SIGNING_SECRET", "s3cr3t"),
            ("SENDBLUE_WEBHOOK_PATH_TOKEN", "p4th"),
        ];
        assert!(verify_sendblue_webhook(
            env(&configured),
            "p4th",
            Some("s3cr3t")
        ));
        // The header alone is not enough to reach the route.
        assert!(!verify_sendblue_webhook(
            env(&configured),
            "wrong",
            Some("s3cr3t")
        ));
        // Nor is the path alone.
        assert!(!verify_sendblue_webhook(env(&configured), "p4th", Some("")));
        assert!(!verify_sendblue_webhook(env(&configured), "p4th", None));
        // Unconfigured never verifies, so a deployment that forgot one of the
        // two secrets is closed rather than open.
        assert!(!verify_sendblue_webhook(
            env(&[("SENDBLUE_WEBHOOK_SIGNING_SECRET", "s3cr3t")]),
            "p4th",
            Some("s3cr3t")
        ));
        assert!(!verify_sendblue_webhook(
            env(&[("SENDBLUE_WEBHOOK_PATH_TOKEN", "p4th")]),
            "p4th",
            Some("s3cr3t")
        ));
        assert!(!verify_sendblue_webhook(
            env(&[
                ("SENDBLUE_WEBHOOK_SIGNING_SECRET", "   "),
                ("SENDBLUE_WEBHOOK_PATH_TOKEN", "p4th"),
            ]),
            "p4th",
            Some("   ")
        ));
    }

    #[test]
    fn parses_a_direct_message() {
        let inbound = parse_sendblue_inbound(&json!({
            "message_handle": "mh-1",
            "from_number": "+15551234567",
            "content": "  hello  ",
        }))
        .unwrap();
        assert_eq!(inbound.message_handle, "mh-1");
        assert_eq!(inbound.chat_id, "+15551234567");
        assert_eq!(inbound.text, "hello");
        assert_eq!(inbound.media_url, None);
    }

    #[test]
    fn a_group_message_threads_on_the_group_id() {
        let inbound = parse_sendblue_inbound(&json!({
            "message_handle": "mh-1",
            "from_number": "+15551234567",
            "group_id": "g-9",
            "content": "hi",
        }))
        .unwrap();
        assert_eq!(inbound.chat_id, "g-9");
        assert_eq!(inbound.sender, "+15551234567");
    }

    #[test]
    fn an_attachment_alone_is_still_an_inbound_message() {
        let inbound = parse_sendblue_inbound(&json!({
            "message_handle": "mh-1",
            "from_number": "+15551234567",
            "content": "",
            "media_url": "https://example.test/a.jpg",
        }))
        .unwrap();
        assert_eq!(inbound.text, "");
        assert_eq!(
            inbound.media_url.as_deref(),
            Some("https://example.test/a.jpg")
        );
    }

    #[test]
    fn refuses_echoes_and_malformed_payloads() {
        for body in [
            json!({ "message_handle": "mh-1", "from_number": "+1", "content": "hi", "is_outbound": true }),
            json!({ "from_number": "+1", "content": "hi" }),
            json!({ "message_handle": "", "from_number": "+1", "content": "hi" }),
            json!({ "message_handle": "mh-1", "content": "hi" }),
            json!({ "message_handle": "mh-1", "from_number": "", "content": "hi" }),
            json!({ "message_handle": "mh-1", "from_number": "+1", "content": "   " }),
            json!({ "message_handle": "mh-1", "from_number": "+1", "content": "a".repeat(20_001) }),
            json!("not an object"),
        ] {
            assert!(
                parse_sendblue_inbound(&body).is_none(),
                "should refuse {body}"
            );
        }
        let long_sender = format!("+{}", "1".repeat(260));
        assert!(parse_sendblue_inbound(
            &json!({ "message_handle": "mh-1", "from_number": long_sender, "content": "hi" })
        )
        .is_none());
    }

    #[test]
    fn the_send_request_is_only_built_when_fully_configured() {
        assert!(!sendblue_configured(env(&[])));
        assert!(!sendblue_configured(env(&[
            ("SENDBLUE_API_KEY_ID", "id"),
            ("SENDBLUE_API_KEY_SECRET", "secret"),
        ])));
        let full = [
            ("SENDBLUE_API_KEY_ID", "id"),
            ("SENDBLUE_API_KEY_SECRET", "secret"),
            ("SENDBLUE_NUMBER", " +15550000000 "),
        ];
        assert!(sendblue_configured(env(&full)));
        assert_eq!(
            sendblue_payload(env(&full), "+15551234567", "hi"),
            json!({
                "number": "+15551234567",
                "from_number": "+15550000000",
                "content": "hi",
            })
        );
    }

    fn headers(id: &str, secret: &str) -> Vec<(String, String)> {
        vec![
            ("sb-api-key-id".to_string(), id.to_string()),
            ("sb-api-secret-key".to_string(), secret.to_string()),
            ("content-type".to_string(), "application/json".to_string()),
        ]
    }

    #[test]
    fn the_send_request_targets_the_documented_endpoint_with_trimmed_credentials() {
        assert_eq!(
            SEND_MESSAGE_ENDPOINT,
            "https://api.sendblue.com/api/send-message"
        );
        assert_eq!(
            sendblue_headers(env(&[
                ("SENDBLUE_API_KEY_ID", "  key-id  "),
                ("SENDBLUE_API_KEY_SECRET", "\tkey-secret\n"),
            ])),
            headers("key-id", "key-secret")
        );
        // An unconfigured deployment still yields the three headers, empty.
        assert_eq!(sendblue_headers(env(&[])), headers("", ""));
    }

    #[test]
    fn the_cli_alias_env_names_configure_the_provider() {
        let alias = [
            ("SENDBLUE_API_KEY", " cli-key "),
            ("SENDBLUE_SECRET_KEY", " cli-secret "),
            ("SENDBLUE_NUMBER", "+15122164639"),
        ];
        assert!(sendblue_configured(env(&alias)));
        assert_eq!(
            sendblue_headers(env(&alias)),
            headers("cli-key", "cli-secret")
        );
        // The canonical names win wherever both are present.
        assert_eq!(
            sendblue_headers(env(&[
                ("SENDBLUE_API_KEY_ID", "key-id"),
                ("SENDBLUE_API_KEY", "cli-key"),
                ("SENDBLUE_SECRET_KEY", "cli-secret"),
            ])),
            headers("key-id", "cli-secret")
        );
        // An alias alone never substitutes for the line the messages come from.
        assert!(!sendblue_configured(env(&[
            ("SENDBLUE_API_KEY", "cli-key"),
            ("SENDBLUE_SECRET_KEY", "cli-secret"),
        ])));
    }
}
