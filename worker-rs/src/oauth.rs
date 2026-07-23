//! Pure OAuth logic ported from `worker/src/oauth-broker.ts` and
//! `worker/src/oauth-proxy.ts`.
//!
//! Covers AES-GCM token encryption at rest (RustCrypto `aes-gcm`, wasm-clean,
//! byte-compatible with the WebCrypto AES-GCM used by the TS worker: 12-byte IV
//! prepended, 16-byte tag appended), provider-config selection, the x.ai
//! discovery endpoint allowlist, the `account_id` pattern, the device-poll
//! error allowlist, and the proxy's refresh-decision + TTL math. The workers-rs
//! I/O (Hono routes, D1, provider `fetch`, discovery cache, refresh lock) lives
//! in `routes_channels.rs`.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;

/// `refreshLeewayMs` in oauth-proxy.ts.
pub const REFRESH_LEEWAY_MS: i64 = 60_000;
/// `defaultRefreshTtlMs` — TTL applied when the refresh response omits
/// `expires_in` (55 minutes).
pub const DEFAULT_REFRESH_TTL_MS: i64 = 55 * 60 * 1000;

/// `importOauthTokenKey` — decode a base64 secret into a 32-byte AES key.
/// Returns `None` for malformed base64 or a non-32-byte key (parity with the
/// WebCrypto `importKey` guard).
pub fn import_oauth_token_key(secret: &str) -> Option<[u8; 32]> {
    let raw = STANDARD.decode(secret).ok()?;
    if raw.len() != 32 {
        return None;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&raw);
    Some(key)
}

/// `encryptOauthToken` — AES-256-GCM encrypt, returning base64 of
/// `iv || ciphertext || tag`. The 12-byte `iv` is supplied by the caller (the
/// glue draws it from a CSPRNG; tests pass a fixed value).
pub fn encrypt_oauth_token(key: &[u8; 32], iv: &[u8; 12], plaintext: &str) -> Option<String> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(iv), plaintext.as_bytes())
        .ok()?;
    let mut combined = Vec::with_capacity(iv.len() + ciphertext.len());
    combined.extend_from_slice(iv);
    combined.extend_from_slice(&ciphertext);
    Some(STANDARD.encode(combined))
}

/// `decryptOauthToken` — reverse of `encrypt_oauth_token`. Returns `None` on
/// malformed base64, a too-short payload, or an authentication failure.
pub fn decrypt_oauth_token(key: &[u8; 32], stored: &str) -> Option<String> {
    let combined = STANDARD.decode(stored).ok()?;
    if combined.len() <= 12 {
        return None;
    }
    let (iv, ciphertext) = combined.split_at(12);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let plaintext = cipher.decrypt(Nonce::from_slice(iv), ciphertext).ok()?;
    String::from_utf8(plaintext).ok()
}

/// A resolved provider configuration (`ProviderConfig` in oauth-broker.ts).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderConfig {
    pub client_id: String,
    pub device_endpoint: String,
    pub token_endpoint: String,
    pub scope: String,
}

/// The upstream chat endpoint per provider (oauth-proxy.ts).
pub const OPENAI_UPSTREAM: &str = "https://chatgpt.com/backend-api/codex/responses";
pub const XAI_UPSTREAM: &str = "https://cli-chat-proxy.grok.com/v1/chat/completions";

/// Static OpenAI provider config, gated on `OPENAI_OAUTH_CLIENT_ID`.
pub fn openai_config(client_id: Option<&str>) -> Option<ProviderConfig> {
    let client_id = client_id.filter(|v| !v.is_empty())?;
    Some(ProviderConfig {
        client_id: client_id.to_string(),
        device_endpoint: "https://auth.openai.com/oauth/device/code".to_string(),
        token_endpoint: "https://auth.openai.com/oauth/token".to_string(),
        scope: "openid profile email offline_access".to_string(),
    })
}

/// x.ai provider config, gated on `XAI_OAUTH_CLIENT_ID` and the discovered
/// endpoints (fetched + cached by the glue).
pub fn xai_config(
    client_id: Option<&str>,
    device_endpoint: &str,
    token_endpoint: &str,
) -> Option<ProviderConfig> {
    let client_id = client_id.filter(|v| !v.is_empty())?;
    Some(ProviderConfig {
        client_id: client_id.to_string(),
        device_endpoint: device_endpoint.to_string(),
        token_endpoint: token_endpoint.to_string(),
        scope: "openid profile offline_access".to_string(),
    })
}

/// `validXaiEndpoint` — https on `x.ai` or a `.x.ai` subdomain.
pub fn valid_xai_endpoint(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("https://") else {
        return false;
    };
    // Host is everything up to the first '/', '?', or '#'.
    let host = rest
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .split('@')
        .next_back()
        .unwrap_or("");
    // Strip an optional port.
    let host = host.split(':').next().unwrap_or("");
    host == "x.ai" || host.ends_with(".x.ai")
}

/// `accountIdPattern` — `^[A-Za-z0-9_-]{1,128}$`.
pub fn valid_account_id(value: &str) -> bool {
    let len = value.chars().count();
    (1..=128).contains(&len)
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Classification of a device-poll upstream error against the allowlist.
#[derive(Debug, PartialEq, Eq)]
pub enum PollOutcome {
    /// Still waiting: HTTP 202 `{ pending: true, error }`.
    Pending(&'static str),
    /// Terminal client error: HTTP 400 `{ error }`.
    Failed(String),
}

const POLL_ERROR_ALLOWLIST: &[&str] = &[
    "authorization_pending",
    "slow_down",
    "expired_token",
    "access_denied",
];

/// Map an upstream device-token error to the client-facing outcome.
/// `error` is `body.error` when it is a string, else `None`.
pub fn classify_poll_error(error: Option<&str>) -> PollOutcome {
    let mapped = match error {
        Some(e) if POLL_ERROR_ALLOWLIST.contains(&e) => e,
        _ => "failed",
    };
    match mapped {
        "authorization_pending" => PollOutcome::Pending("authorization_pending"),
        "slow_down" => PollOutcome::Pending("slow_down"),
        other => PollOutcome::Failed(other.to_string()),
    }
}

/// Whether the proxy must refresh before using the access token.
/// `expires_at.is_some() && expires_at <= now + leeway`.
pub fn needs_refresh(expires_at: Option<i64>, now_ms: i64) -> bool {
    match expires_at {
        Some(exp) => exp <= now_ms + REFRESH_LEEWAY_MS,
        None => false,
    }
}

/// Expiry to store after a refresh: `now + expires_in*1000`, or the fallback
/// TTL when `expires_in` is absent (oauth-proxy.ts).
pub fn refreshed_expires_at(now_ms: i64, expires_in_seconds: Option<f64>) -> i64 {
    match expires_in_seconds {
        Some(seconds) => now_ms + (seconds * 1000.0) as i64,
        None => now_ms + DEFAULT_REFRESH_TTL_MS,
    }
}

/// Expiry stored after a device poll: `now + expires_in*1000` when present,
/// else NULL (oauth-broker.ts).
pub fn connection_expires_at(now_ms: i64, expires_in_seconds: Option<f64>) -> Option<i64> {
    expires_in_seconds.map(|seconds| now_ms + (seconds * 1000.0) as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> [u8; 32] {
        let mut k = [0u8; 32];
        for (i, b) in k.iter_mut().enumerate() {
            *b = i as u8;
        }
        k
    }

    #[test]
    fn import_key_requires_32_bytes() {
        let secret = STANDARD.encode(key());
        assert_eq!(import_oauth_token_key(&secret), Some(key()));
        assert_eq!(import_oauth_token_key(&STANDARD.encode([0u8; 16])), None);
        assert_eq!(import_oauth_token_key("not base64!!!"), None);
    }

    #[test]
    fn aes_gcm_round_trip() {
        let iv = [7u8; 12];
        let stored = encrypt_oauth_token(&key(), &iv, "secret-token").unwrap();
        assert_eq!(
            decrypt_oauth_token(&key(), &stored).as_deref(),
            Some("secret-token")
        );
    }

    #[test]
    fn decrypt_rejects_tamper_and_short() {
        let iv = [1u8; 12];
        let mut stored = encrypt_oauth_token(&key(), &iv, "hello").unwrap();
        // Flip a character in the ciphertext body -> auth tag fails.
        let bytes = STANDARD.decode(&stored).unwrap();
        let mut tampered = bytes.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xFF;
        stored = STANDARD.encode(tampered);
        assert_eq!(decrypt_oauth_token(&key(), &stored), None);
        // Too-short payload.
        assert_eq!(
            decrypt_oauth_token(&key(), &STANDARD.encode([0u8; 8])),
            None
        );
        // Wrong key fails.
        let iv2 = [2u8; 12];
        let ok = encrypt_oauth_token(&key(), &iv2, "hi").unwrap();
        assert_eq!(decrypt_oauth_token(&[9u8; 32], &ok), None);
    }

    #[test]
    fn openai_config_gated_on_client_id() {
        assert!(openai_config(None).is_none());
        assert!(openai_config(Some("")).is_none());
        let cfg = openai_config(Some("cid")).unwrap();
        assert_eq!(cfg.token_endpoint, "https://auth.openai.com/oauth/token");
        assert_eq!(cfg.scope, "openid profile email offline_access");
    }

    #[test]
    fn xai_config_uses_discovered_endpoints() {
        assert!(xai_config(None, "a", "b").is_none());
        let cfg = xai_config(
            Some("cid"),
            "https://auth.x.ai/device",
            "https://auth.x.ai/token",
        )
        .unwrap();
        assert_eq!(cfg.device_endpoint, "https://auth.x.ai/device");
        assert_eq!(cfg.scope, "openid profile offline_access");
    }

    #[test]
    fn xai_endpoint_allowlist() {
        assert!(valid_xai_endpoint("https://x.ai/token"));
        assert!(valid_xai_endpoint("https://auth.x.ai/device"));
        assert!(valid_xai_endpoint("https://auth.x.ai:443/device"));
        assert!(!valid_xai_endpoint("http://x.ai/token"));
        assert!(!valid_xai_endpoint("https://evil.com/x.ai"));
        assert!(!valid_xai_endpoint("https://notx.ai"));
        assert!(!valid_xai_endpoint("https://x.ai.evil.com/token"));
    }

    #[test]
    fn account_id_pattern() {
        assert!(valid_account_id("abc-123_XYZ"));
        assert!(valid_account_id(&"a".repeat(128)));
        assert!(!valid_account_id(""));
        assert!(!valid_account_id(&"a".repeat(129)));
        assert!(!valid_account_id("has space"));
        assert!(!valid_account_id("dots.not.allowed"));
    }

    #[test]
    fn poll_error_classification() {
        assert_eq!(
            classify_poll_error(Some("authorization_pending")),
            PollOutcome::Pending("authorization_pending")
        );
        assert_eq!(
            classify_poll_error(Some("slow_down")),
            PollOutcome::Pending("slow_down")
        );
        assert_eq!(
            classify_poll_error(Some("expired_token")),
            PollOutcome::Failed("expired_token".into())
        );
        assert_eq!(
            classify_poll_error(Some("access_denied")),
            PollOutcome::Failed("access_denied".into())
        );
        // Not on the allowlist collapses to "failed".
        assert_eq!(
            classify_poll_error(Some("invalid_grant")),
            PollOutcome::Failed("failed".into())
        );
        assert_eq!(
            classify_poll_error(None),
            PollOutcome::Failed("failed".into())
        );
    }

    #[test]
    fn refresh_decision_and_ttl() {
        assert!(!needs_refresh(None, 1_000));
        assert!(needs_refresh(Some(1_000), 1_000)); // exp <= now + leeway
        assert!(needs_refresh(Some(1_000 + REFRESH_LEEWAY_MS), 1_000));
        assert!(!needs_refresh(Some(1_001 + REFRESH_LEEWAY_MS), 1_000));

        assert_eq!(refreshed_expires_at(1_000, Some(60.0)), 61_000);
        assert_eq!(
            refreshed_expires_at(1_000, None),
            1_000 + DEFAULT_REFRESH_TTL_MS
        );
        assert_eq!(connection_expires_at(1_000, Some(30.0)), Some(31_000));
        assert_eq!(connection_expires_at(1_000, None), None);
    }
}
