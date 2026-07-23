//! Pure port of the Gemini Live ephemeral-token shaping in
//! `worker/src/voice.ts`: the two-use, model-locked token request body, the
//! ISO expiry timestamps, and the response parse. The fetch/ledger is glue.

use serde_json::{json, Value};

pub const TOKEN_ENDPOINT: &str = "https://generativelanguage.googleapis.com/v1alpha/auth_tokens";

/// Format an epoch-millisecond instant as a JS `Date.toISOString()` string:
/// `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC, millisecond precision).
pub fn iso_from_epoch_ms(epoch_ms: i64) -> String {
    let ms = epoch_ms.rem_euclid(1000);
    let mut secs = epoch_ms.div_euclid(1000);
    let time_of_day = secs.rem_euclid(86_400);
    let days = secs.div_euclid(86_400);
    secs = time_of_day;
    let hour = secs / 3600;
    let minute = (secs % 3600) / 60;
    let second = secs % 60;
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{ms:03}Z")
}

/// Howard Hinnant's civil-from-days algorithm (days since 1970-01-01).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year, m as u32, d as u32)
}

/// The token expiry (10 minutes) and new-session expiry (60 seconds) ISO
/// timestamps derived from `now`, matching the TS route.
pub fn expiry_times(now_ms: i64) -> (String, String) {
    (
        iso_from_epoch_ms(now_ms + 10 * 60 * 1000),
        iso_from_epoch_ms(now_ms + 60 * 1000),
    )
}

/// The token-mint request body: two uses, the two expiries, and the model
/// lock via `liveConnectConstraints`.
pub fn token_request_body(now_ms: i64, model: &str) -> Value {
    let (expire_time, new_session_expire_time) = expiry_times(now_ms);
    json!({
        "uses": 2,
        "expireTime": expire_time,
        "newSessionExpireTime": new_session_expire_time,
        "liveConnectConstraints": { "model": model },
    })
}

/// The client-facing response body once a token `name` is minted.
pub fn client_response(now_ms: i64, model: &str, token_name: &str) -> Value {
    let (expire_time, new_session_expire_time) = expiry_times(now_ms);
    json!({
        "token": token_name,
        "model": model,
        "expireTime": expire_time,
        "newSessionExpireTime": new_session_expire_time,
    })
}

/// Port of the response parse: a string `name` field, or `None`.
pub fn parse_token_name(value: &Value) -> Option<String> {
    value
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_matches_known_instants() {
        assert_eq!(iso_from_epoch_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_from_epoch_ms(1_000), "1970-01-01T00:00:01.000Z");
        // 2021-01-01T00:00:00.000Z = 1609459200000 ms.
        assert_eq!(
            iso_from_epoch_ms(1_609_459_200_000),
            "2021-01-01T00:00:00.000Z"
        );
        // With sub-second component.
        assert_eq!(
            iso_from_epoch_ms(1_609_459_200_123),
            "2021-01-01T00:00:00.123Z"
        );
    }

    #[test]
    fn token_request_is_model_locked_and_two_use() {
        let body = token_request_body(0, "gemini-3.1-flash-live-preview");
        assert_eq!(body["uses"], json!(2));
        assert_eq!(
            body["liveConnectConstraints"]["model"],
            json!("gemini-3.1-flash-live-preview")
        );
        assert_eq!(body["expireTime"], json!("1970-01-01T00:10:00.000Z"));
        assert_eq!(
            body["newSessionExpireTime"],
            json!("1970-01-01T00:01:00.000Z")
        );
    }

    #[test]
    fn client_response_does_not_carry_the_key_and_echoes_model() {
        let body = client_response(
            0,
            "gemini-3.1-flash-live-preview",
            "auth_tokens/ephemeral-123",
        );
        assert_eq!(body["token"], json!("auth_tokens/ephemeral-123"));
        assert_eq!(body["model"], json!("gemini-3.1-flash-live-preview"));
        assert!(!body.to_string().contains("gemini-secret"));
    }

    #[test]
    fn parses_token_name() {
        assert_eq!(
            parse_token_name(&json!({ "name": "auth_tokens/ephemeral-123" })).as_deref(),
            Some("auth_tokens/ephemeral-123")
        );
        assert_eq!(parse_token_name(&json!({})), None);
        assert_eq!(parse_token_name(&json!({ "name": 5 })), None);
    }
}
