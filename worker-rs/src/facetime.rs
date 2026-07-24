//! Pure parity port of `worker/src/facetime.ts`.
//!
//! Sendblue's FaceTime bridge. Unlike the previous provider it does not hand
//! back a `facetime.apple.com` join link — it rings the handle over FaceTime
//! Audio and returns Agora WebRTC credentials for the call's audio channel.
//! There is no Apple web client and no browser anywhere in this path; the audio
//! is joined server-side by the bridge container.
//!
//! The container/Durable-Object bridge itself (`facetime-session.ts`,
//! `facetime-bridge.ts`) is not ported: see `PORT_STATUS.md`. What is here is
//! the whole API surface — handle validation, the provider call's outcome
//! mapping, the derived session id and the session link.

use serde_json::Value;

use crate::crypto_util::sha256_hex;

pub const FACETIME_ENDPOINT: &str = "https://api.sendblue.com/facetime/start-call";
pub const UPSTREAM_TIMEOUT_MS: i64 = 15_000;
pub const HANDLE_MAX_CHARACTERS: usize = 254;

/// The custom domain this Worker is deployed on, used when `APP_URL` is unset.
pub const DEFAULT_APP_URL: &str = "https://omi.tsc.hk";

/// `phonePattern = /^\+[1-9]\d{6,14}$/`
fn is_e164(handle: &str) -> bool {
    let Some(rest) = handle.strip_prefix('+') else {
        return false;
    };
    match rest.bytes().next() {
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

/// Sendblue dials an E.164 number. An email handle is a valid FaceTime identity
/// but not something this provider can ring.
pub fn is_diallable_handle(handle: &str) -> bool {
    is_e164(handle)
}

/// `idempotencyKey(uid, token)` — SHA-256 of `"<uid> facetime <token>"`, hex.
pub fn idempotency_key(uid: &str, token: &str) -> String {
    sha256_hex(&format!("{uid} facetime {token}"))
}

/// The idempotency key decides the session id, so a retry lands on the same
/// admission reservation instead of placing a second call. The first 16 bytes
/// of the same digest, hex — `faceTimeSessionId` in `public-api.ts`.
pub fn session_id(uid: &str, token: &str) -> String {
    idempotency_key(uid, token)[..32].to_string()
}

/// The provider no longer returns an Apple join link: the call's audio is
/// joined server-side by the bridge. `link` is kept in the contract and points
/// at this session so existing clients keep working.
pub fn session_link(app_url: Option<&str>, session_id: &str) -> String {
    let base = app_url
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(DEFAULT_APP_URL);
    // `new URL("/facetime/sessions/…", base)` resolves against the base's
    // origin, so any path on `APP_URL` is replaced rather than prefixed.
    let origin = match base.find("://") {
        Some(scheme) => match base[scheme + 3..].find('/') {
            Some(path) => &base[..scheme + 3 + path],
            None => base,
        },
        None => base.split('/').next().unwrap_or(base),
    };
    format!("{origin}/facetime/sessions/{session_id}")
}

/// What the bridge needs to join the call's audio channel. `uid` is the Agora
/// user id the bridge publishes under; 0 means "let Agora assign one".
#[derive(Clone, Debug, PartialEq)]
pub struct AgoraCredentials {
    pub app_id: String,
    pub channel_name: String,
    pub token: String,
    pub uid: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum FaceTimeOutcome {
    Ok {
        handle: String,
        agora: AgoraCredentials,
    },
    Unconfigured,
    /// The account has no FaceTime line provisioned (Sendblue gates the route
    /// on a purchased FaceTime number). That is an expected product state, not
    /// a fault of ours: callers get a clear "not yet available" and nothing is
    /// queued for retry.
    Unavailable,
    Rejected {
        status: u16,
    },
    Failed,
}

pub fn facetime_provider_configured(env: impl Fn(&str) -> Option<String>) -> bool {
    [
        "SENDBLUE_API_KEY_ID",
        "SENDBLUE_API_KEY_SECRET",
        "SENDBLUE_FACETIME_NUMBER",
    ]
    .iter()
    .all(|name| {
        env(name)
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false)
    })
}

fn credentials_from(value: Option<&Value>) -> Option<AgoraCredentials> {
    let agora = value?.as_object()?;
    let app_id = agora.get("appId")?.as_str()?;
    let channel_name = agora.get("channelName")?.as_str()?;
    let token = agora.get("token")?.as_str()?;
    if app_id.is_empty() || channel_name.is_empty() || token.is_empty() {
        return None;
    }
    // Bound every field: these are forwarded verbatim into the container's
    // start request, so an oversized upstream value must not become our payload.
    if app_id.chars().count() > 128
        || channel_name.chars().count() > 256
        || token.chars().count() > 4_096
    {
        return None;
    }
    let uid = match agora.get("uid") {
        None | Some(Value::Null) => 0.0,
        Some(value) => crate::jsnum::number_from_value(value),
    };
    if !crate::jsnum::is_safe_integer(uid) || uid < 0.0 || uid > u32::MAX as f64 {
        return None;
    }
    Some(AgoraCredentials {
        app_id: app_id.to_string(),
        channel_name: channel_name.to_string(),
        token: token.to_string(),
        uid: uid as u32,
    })
}

/// Maps an upstream status + body to an outcome. `body` is `None` when the
/// response carried no parseable JSON.
///
/// 401 is our credentials, not the account's product state, so it reads as
/// "unconfigured". 402/403/404/501 all mean "no FaceTime line on this account"
/// and keep the graceful not-provisioned surface.
pub fn outcome_for(status: u16, body: Option<&Value>, handle: &str) -> FaceTimeOutcome {
    if status == 401 {
        return FaceTimeOutcome::Unconfigured;
    }
    if matches!(status, 402 | 403 | 404 | 501) {
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
    if body.get("status").and_then(Value::as_str) != Some("OK") {
        return FaceTimeOutcome::Failed;
    }
    match credentials_from(body.get("agora")) {
        Some(agora) => FaceTimeOutcome::Ok {
            handle: handle.to_string(),
            agora,
        },
        None => FaceTimeOutcome::Failed,
    }
}

/// The provider request body.
pub fn upstream_body(handle: &str, from_number: &str) -> Value {
    serde_json::json!({ "phoneNumber": handle, "fromNumber": from_number.trim() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn handle(value: &str) -> Option<String> {
        normalize_handle(Some(&json!(value)))
    }

    fn agora() -> Value {
        json!({ "appId": "app", "channelName": "chan", "token": "tok" })
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
        // Valid FaceTime identity, but this provider cannot ring it.
        assert!(!is_diallable_handle("person@example.com"));
        assert!(is_diallable_handle("+15551234567"));
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
    fn derives_a_stable_idempotency_key_and_session_id_per_uid_and_token() {
        let a = idempotency_key("uid-1", "token");
        assert_eq!(a, idempotency_key("uid-1", "token"));
        assert_ne!(a, idempotency_key("uid-2", "token"));
        assert_ne!(a, idempotency_key("uid-1", "other"));
        assert_eq!(a.len(), 64);
        assert_eq!(session_id("uid-1", "token"), a[..32]);
        assert_eq!(session_id("uid-1", "token").len(), 32);
    }

    #[test]
    fn the_session_link_falls_back_to_the_deployed_domain() {
        assert_eq!(
            session_link(None, "abc"),
            "https://omi.tsc.hk/facetime/sessions/abc"
        );
        assert_eq!(
            session_link(Some("  "), "abc"),
            "https://omi.tsc.hk/facetime/sessions/abc"
        );
        assert_eq!(
            session_link(Some("https://app.example/"), "abc"),
            "https://app.example/facetime/sessions/abc"
        );
        // A base carrying a path resolves against its origin, as `new URL` does.
        assert_eq!(
            session_link(Some("https://app.example/hub"), "abc"),
            "https://app.example/facetime/sessions/abc"
        );
    }

    #[test]
    fn distinguishes_our_credentials_from_an_unprovisioned_account() {
        assert_eq!(
            outcome_for(401, None, "+15551234567"),
            FaceTimeOutcome::Unconfigured
        );
        for status in [402, 403, 404, 501] {
            assert_eq!(
                outcome_for(status, None, "+15551234567"),
                FaceTimeOutcome::Unavailable,
                "status {status} means no FaceTime line"
            );
        }
        for status in [400, 422] {
            assert_eq!(
                outcome_for(status, None, "+15551234567"),
                FaceTimeOutcome::Rejected { status }
            );
        }
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
    fn returns_agora_credentials_on_success() {
        assert_eq!(
            outcome_for(
                200,
                Some(&json!({ "status": "OK", "agora": agora() })),
                "+15551234567"
            ),
            FaceTimeOutcome::Ok {
                handle: "+15551234567".into(),
                agora: AgoraCredentials {
                    app_id: "app".into(),
                    channel_name: "chan".into(),
                    token: "tok".into(),
                    uid: 0,
                },
            }
        );
        let mut with_uid = agora();
        with_uid["uid"] = json!(42);
        let FaceTimeOutcome::Ok { agora, .. } = outcome_for(
            201,
            Some(&json!({ "status": "OK", "agora": with_uid })),
            "+15551234567",
        ) else {
            panic!("expected a successful outcome");
        };
        assert_eq!(agora.uid, 42);
    }

    #[test]
    fn an_untruthful_or_oversized_success_body_is_a_failure() {
        let oversized = json!({
            "appId": "a".repeat(129),
            "channelName": "chan",
            "token": "tok",
        });
        for body in [
            json!({ "status": "ok", "agora": agora() }),
            json!({ "status": "OK" }),
            json!({ "agora": agora() }),
            json!({ "status": "OK", "agora": { "appId": "", "channelName": "c", "token": "t" } }),
            json!({ "status": "OK", "agora": { "channelName": "c", "token": "t" } }),
            json!({ "status": "OK", "agora": oversized }),
            json!({ "status": "OK", "agora": { "appId": "a", "channelName": "c", "token": "t", "uid": -1 } }),
            json!({ "status": "OK", "agora": { "appId": "a", "channelName": "c", "token": "t", "uid": 4294967296i64 } }),
        ] {
            assert_eq!(
                outcome_for(200, Some(&body), "+15551234567"),
                FaceTimeOutcome::Failed,
                "should fail for {body}"
            );
        }
    }

    #[test]
    fn the_provider_is_configured_only_with_a_facetime_number() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs
                    .iter()
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| (*value).to_string())
            }
        };
        assert!(!facetime_provider_configured(env(&[])));
        assert!(!facetime_provider_configured(env(&[
            ("SENDBLUE_API_KEY_ID", "id"),
            ("SENDBLUE_API_KEY_SECRET", "secret"),
        ])));
        assert!(facetime_provider_configured(env(&[
            ("SENDBLUE_API_KEY_ID", "id"),
            ("SENDBLUE_API_KEY_SECRET", "secret"),
            ("SENDBLUE_FACETIME_NUMBER", "+15550000000"),
        ])));
        assert_eq!(
            upstream_body("+15551234567", " +15550000000 "),
            json!({ "phoneNumber": "+15551234567", "fromNumber": "+15550000000" })
        );
    }
}
