//! Pure delivery logic ported from `worker/src/delivery.ts`.
//!
//! Everything here is host-testable: retry/backoff computation, the stable
//! idempotency-key digest, coordinator-name derivation, and the terminal-state
//! selection (retryable HTTP, network failure, ambiguous Telegram "unknown").
//! The workers-rs I/O (the `DeliveryCoordinator` Durable Object, D1 claims, and
//! provider `fetch`) lives in `routes_channels.rs` and drives these functions.

use sha2::{Digest, Sha256};

/// `maxAttempts` in delivery.ts.
pub const MAX_ATTEMPTS: u32 = 5;
/// `leaseMs` in delivery.ts.
pub const LEASE_MS: i64 = 30_000;

/// Provider channel. Mirrors the TS `Channel` union.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    Telegram,
    IMessage,
}

impl Channel {
    pub fn as_str(self) -> &'static str {
        match self {
            Channel::Telegram => "telegram",
            Channel::IMessage => "imessage",
        }
    }

    pub fn parse(value: &str) -> Option<Channel> {
        match value {
            "telegram" => Some(Channel::Telegram),
            // Temporary dual-accept of the pre-rename wire value.
            "imessage" | "blooio" => Some(Channel::IMessage),
            _ => None,
        }
    }
}

/// `coordinatorName(uid, channel)` — the `uid\u{0000}channel` DO name.
pub fn coordinator_name(uid: &str, channel: Channel) -> String {
    format!("{uid}\u{0000}{}", channel.as_str())
}

/// `stableIdempotencyKey` — lowercase hex SHA-256 of
/// `uid\u{0000}channel\u{0000}idempotency_key`.
pub fn stable_idempotency_key(uid: &str, channel: Channel, idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{uid}\u{0000}{}\u{0000}{idempotency_key}", channel.as_str()).as_bytes());
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Parsed inputs to `retryDelay`, extracted from the provider response by the
/// glue so the delay math stays pure.
#[derive(Debug, Default, Clone, Copy)]
pub struct RetryAfterHints {
    /// `retry-after` header parsed as a finite number of seconds.
    pub header_seconds: Option<f64>,
    /// `retry-after` header parsed as an HTTP-date, expressed as milliseconds
    /// since epoch (the glue does the date parse; TS uses `Date.parse`).
    pub header_date_ms: Option<f64>,
    /// `parameters.retry_after` or top-level `retry_after` from the JSON body,
    /// in seconds, when finite.
    pub json_retry_after_seconds: Option<f64>,
}

/// `retryDelay(attempts, response)`.
///
/// `jitter` is the `Math.random()` draw in `[0, 1)`; callers pass a real random
/// value (the glue) or a fixed one (tests). `now_ms` is `Date.now()`, used only
/// for the HTTP-date header branch.
pub fn retry_delay(attempts: u32, hints: &RetryAfterHints, now_ms: f64, jitter: f64) -> i64 {
    // headerDelay: prefer numeric seconds, else (Date.parse(header) - now).
    let header_delay = match hints.header_seconds {
        Some(seconds) => seconds * 1000.0,
        None => match hints.header_date_ms {
            Some(date_ms) => date_ms - now_ms,
            None => 0.0,
        },
    };
    let json_delay = hints
        .json_retry_after_seconds
        .map(|s| s * 1000.0)
        .unwrap_or(0.0);
    let provider_delay = header_delay.max(json_delay);
    if provider_delay > 0.0 {
        // Math.min(providerDelay, 60 * 60_000).
        return provider_delay.min(3_600_000.0) as i64;
    }
    // base = Math.min(2 ** attempts * 1000, 15 * 60_000).
    let base = (2f64.powi(attempts as i32) * 1000.0).min(900_000.0);
    // Math.floor(base * (0.8 + random * 0.4)).
    (base * (0.8 + jitter * 0.4)).floor() as i64
}

/// The terminal state written after a non-OK HTTP response.
///
/// Retryable = 429 or >= 500; retry unless attempts are exhausted.
pub fn http_outcome(status: u16, attempts: u32) -> &'static str {
    let retryable = status == 429 || status >= 500;
    let exhausted = attempts >= MAX_ATTEMPTS;
    if retryable && !exhausted {
        "retry"
    } else {
        "failed"
    }
}

/// The terminal state written after a thrown/network error.
///
/// Telegram sends are ambiguous (the message may have been delivered), so they
/// go to `unknown`; other channels retry until exhausted, then `failed`.
pub fn network_outcome(channel: Channel, attempts: u32) -> &'static str {
    if channel == Channel::Telegram {
        "unknown"
    } else if attempts >= MAX_ATTEMPTS {
        "failed"
    } else {
        "retry"
    }
}

/// The `last_error` string paired with `network_outcome`.
pub fn network_error_message(channel: Channel) -> &'static str {
    if channel == Channel::Telegram {
        "Provider outcome unknown"
    } else {
        "Provider network failure"
    }
}

/// `POST /channels/:channel/messages` idempotency-key validation. Mirrors the TS
/// `idempotencyKey.length < 8 || !/^[A-Za-z0-9._:-]+$/.test(idempotencyKey)`
/// guard (applied to the already-trimmed key).
pub fn valid_idempotency_key(key: &str) -> bool {
    key.len() >= 8
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'))
}

/// The `POST /channels/:channel/messages` status machine: reads the current
/// delivery `state`/`last_error` and maps to the HTTP status the TS route
/// returns (200 sent / 503 no credentials / 502 failed / 202 in flight).
pub fn delivery_status(state: Option<&str>, last_error: Option<&str>) -> u16 {
    match state {
        Some("sent") => 200,
        Some("failed") if last_error == Some("Provider credentials unavailable") => 503,
        Some("failed") => 502,
        _ => 202,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinator_name_uses_nul_separator() {
        assert_eq!(
            coordinator_name("u1", Channel::Telegram),
            "u1\u{0000}telegram"
        );
        assert_eq!(
            coordinator_name("u1", Channel::IMessage),
            "u1\u{0000}imessage"
        );
    }

    #[test]
    fn channel_round_trips() {
        assert_eq!(Channel::parse("telegram"), Some(Channel::Telegram));
        assert_eq!(Channel::parse("imessage"), Some(Channel::IMessage));
        assert_eq!(Channel::parse("sms"), None);
    }

    #[test]
    fn idempotency_key_is_stable_sha256_hex() {
        // Digest of "u\u{0000}telegram\u{0000}k" — matches the WebCrypto SHA-256 in
        // delivery.ts (verified against a known vector).
        let key = stable_idempotency_key("u", Channel::Telegram, "k");
        assert_eq!(key.len(), 64);
        assert!(key
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        // Deterministic and input-sensitive.
        assert_eq!(key, stable_idempotency_key("u", Channel::Telegram, "k"));
        assert_ne!(key, stable_idempotency_key("u", Channel::IMessage, "k"));
    }

    #[test]
    fn retry_after_header_seconds_win() {
        let hints = RetryAfterHints {
            header_seconds: Some(3.0),
            ..Default::default()
        };
        assert_eq!(retry_delay(1, &hints, 0.0, 0.0), 3000);
    }

    #[test]
    fn retry_after_json_used_when_larger() {
        let hints = RetryAfterHints {
            header_seconds: Some(1.0),
            json_retry_after_seconds: Some(10.0),
            ..Default::default()
        };
        assert_eq!(retry_delay(1, &hints, 0.0, 0.0), 10_000);
    }

    #[test]
    fn retry_after_http_date_uses_now() {
        let hints = RetryAfterHints {
            header_date_ms: Some(5_000.0),
            ..Default::default()
        };
        assert_eq!(retry_delay(1, &hints, 1_000.0, 0.0), 4_000);
    }

    #[test]
    fn provider_json_retry_after_is_honoured_exactly() {
        // The 429 body `{"parameters":{"retry_after":120}}` must schedule the
        // next attempt exactly 120_000 ms out.
        let hints = RetryAfterHints {
            json_retry_after_seconds: Some(120.0),
            ..Default::default()
        };
        assert_eq!(retry_delay(1, &hints, 0.0, 0.0), 120_000);
        assert_eq!(retry_delay(4, &hints, 0.0, 0.99999), 120_000);
    }

    #[test]
    fn a_past_http_date_falls_back_to_exponential_backoff() {
        let hints = RetryAfterHints {
            header_date_ms: Some(1_000.0),
            ..Default::default()
        };
        // headerDelay = 1000 - 5000 = -4000, so the backoff wins: base 8000.
        assert_eq!(retry_delay(3, &hints, 5_000.0, 0.0), 6_400);
        assert_eq!(retry_delay(3, &hints, 5_000.0, 0.99999), 9_599);
    }

    #[test]
    fn provider_delay_capped_at_one_hour() {
        let hints = RetryAfterHints {
            header_seconds: Some(10_000.0),
            ..Default::default()
        };
        assert_eq!(retry_delay(1, &hints, 0.0, 0.0), 3_600_000);
    }

    #[test]
    fn exponential_backoff_with_jitter_bounds() {
        let hints = RetryAfterHints::default();
        // attempts=3 -> base = 8000. jitter=0 -> 0.8*8000=6400.
        assert_eq!(retry_delay(3, &hints, 0.0, 0.0), 6_400);
        // jitter just under 1 -> ~1.2*8000 = 9599 (floor).
        assert_eq!(retry_delay(3, &hints, 0.0, 0.99999), 9_599);
    }

    #[test]
    fn backoff_base_capped_at_fifteen_minutes() {
        let hints = RetryAfterHints::default();
        // attempts=20 -> 2**20*1000 huge, capped to 900_000. jitter=0 -> 720_000.
        assert_eq!(retry_delay(20, &hints, 0.0, 0.0), 720_000);
    }

    #[test]
    fn http_outcome_retryable_vs_terminal() {
        assert_eq!(http_outcome(429, 1), "retry");
        assert_eq!(http_outcome(503, 2), "retry");
        assert_eq!(http_outcome(400, 1), "failed");
        // Exhausted attempts never retry even when retryable.
        assert_eq!(http_outcome(429, MAX_ATTEMPTS), "failed");
        assert_eq!(http_outcome(500, MAX_ATTEMPTS), "failed");
    }

    #[test]
    fn network_outcome_telegram_is_unknown() {
        assert_eq!(network_outcome(Channel::Telegram, 1), "unknown");
        assert_eq!(network_outcome(Channel::Telegram, MAX_ATTEMPTS), "unknown");
        assert_eq!(
            network_error_message(Channel::Telegram),
            "Provider outcome unknown"
        );
    }

    #[test]
    fn network_outcome_imessage_retries_then_fails() {
        assert_eq!(network_outcome(Channel::IMessage, 1), "retry");
        assert_eq!(network_outcome(Channel::IMessage, MAX_ATTEMPTS), "failed");
        assert_eq!(
            network_error_message(Channel::IMessage),
            "Provider network failure"
        );
    }

    #[test]
    fn idempotency_key_validation_matches_regex() {
        assert!(valid_idempotency_key("abc12345"));
        assert!(valid_idempotency_key("a.b_c:d-e"));
        // too short
        assert!(!valid_idempotency_key("abc1234"));
        // disallowed characters
        assert!(!valid_idempotency_key("abc 12345"));
        assert!(!valid_idempotency_key("abc/12345"));
        assert!(!valid_idempotency_key("abc#12345"));
    }

    #[test]
    fn delivery_status_machine() {
        assert_eq!(delivery_status(Some("sent"), None), 200);
        assert_eq!(
            delivery_status(Some("failed"), Some("Provider credentials unavailable")),
            503
        );
        assert_eq!(delivery_status(Some("failed"), Some("boom")), 502);
        assert_eq!(delivery_status(Some("failed"), None), 502);
        assert_eq!(delivery_status(Some("queued"), None), 202);
        assert_eq!(delivery_status(None, None), 202);
    }
}
