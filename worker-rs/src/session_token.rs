//! Session credentials issued by this worker, replacing Firebase ID tokens.
//!
//! Two credentials, deliberately different in kind:
//!
//! * **Access token** — a compact HS256 JWT, minutes-lived, verified with no
//!   database read. Stateless because it expires fast enough that revocation
//!   through expiry is acceptable.
//! * **Refresh token** — opaque high-entropy bytes, long-lived, and only its
//!   SHA-256 digest is ever stored. Revocable, because a row can be deleted.
//!   This is the same shape `api_keys` uses, for the same reason: a database
//!   read must not recover a usable credential.
//!
//! No new dependency: `hmac`, `sha2`, `base64` and `subtle` are already in the
//! tree, and a JWT is a signature over two base64url segments. Pulling a JWT
//! crate would add a wasm-compatibility surface to maintain for ~60 lines of
//! logic.
//!
//! Everything here is pure and host-testable; D1 and HTTP live in the glue.

use serde_json::{json, Value};

use crate::crypto_util::{base64url, constant_time_eq, hmac_sha256_hex, sha256_hex};

/// Access tokens are short so that revoking a session by deleting its refresh
/// row takes effect quickly without a per-request database read.
pub const ACCESS_TOKEN_TTL_MS: i64 = 15 * 60_000;

/// Refresh tokens outlive the app being closed for a while, but not forever.
pub const REFRESH_TOKEN_TTL_MS: i64 = 60 * 24 * 60 * 60_000;

/// Clock skew allowed when checking `exp` and `nbf`.
pub const CLOCK_SKEW_MS: i64 = 60_000;

/// Bytes of entropy in a refresh token. 32 bytes is the same budget
/// `api_keys` spends, and is far beyond guessing.
pub const REFRESH_TOKEN_BYTES: usize = 32;

const HEADER_B64: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// What a verified access token carries. Deliberately minimal — anything that
/// can change during a session's life must be read from the database, not
/// trusted from a token minted minutes ago.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionClaims {
    pub uid: String,
    pub session_id: String,
    pub issued_at_ms: i64,
    pub expires_at_ms: i64,
}

/// Why a token was refused. Callers map every variant to the same 401 — the
/// distinction is for logs, never for the response body, which must not tell
/// an attacker which half of the check failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenError {
    Malformed,
    BadSignature,
    Expired,
    NotYetValid,
}

/// Mints an access token for `uid`/`session_id`.
pub fn issue_access_token(
    uid: &str,
    session_id: &str,
    now_ms: i64,
    ttl_ms: i64,
    secret: &str,
) -> String {
    let payload = json!({
        "sub": uid,
        "sid": session_id,
        "iat": now_ms,
        "exp": now_ms.saturating_add(ttl_ms),
    });
    let body = base64url(payload.to_string().as_bytes());
    let signing_input = format!("{HEADER_B64}.{body}");
    let signature = sign(&signing_input, secret);
    format!("{signing_input}.{signature}")
}

/// Verifies a token against `secret`, then against `previous_secret` if one is
/// supplied. Two secrets exist so a signing key can be rotated without
/// signing every live session out.
pub fn verify_access_token(
    token: &str,
    now_ms: i64,
    secret: &str,
    previous_secret: Option<&str>,
) -> Result<SessionClaims, TokenError> {
    let mut parts = token.split('.');
    let (Some(header), Some(body), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(TokenError::Malformed);
    };
    // The header is fixed rather than parsed. Reading `alg` from the token is
    // how JWT implementations end up accepting `none` or confusing HS256 with
    // RS256; there is only ever one algorithm here, so there is nothing to read.
    if header != HEADER_B64 {
        return Err(TokenError::Malformed);
    }

    let signing_input = format!("{header}.{body}");
    let expected = sign(&signing_input, secret);
    let matched = constant_time_eq(&expected, signature)
        || previous_secret
            .is_some_and(|previous| constant_time_eq(&sign(&signing_input, previous), signature));
    if !matched {
        return Err(TokenError::BadSignature);
    }

    let decoded = decode_segment(body).ok_or(TokenError::Malformed)?;
    let claims: Value = serde_json::from_slice(&decoded).map_err(|_| TokenError::Malformed)?;
    let uid = claims
        .get("sub")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let session_id = claims
        .get("sid")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let issued_at_ms = claims.get("iat").and_then(Value::as_i64);
    let expires_at_ms = claims.get("exp").and_then(Value::as_i64);
    let (Some(issued_at_ms), Some(expires_at_ms)) = (issued_at_ms, expires_at_ms) else {
        return Err(TokenError::Malformed);
    };
    if uid.is_empty() || session_id.is_empty() {
        return Err(TokenError::Malformed);
    }
    if now_ms.saturating_add(CLOCK_SKEW_MS) < issued_at_ms {
        return Err(TokenError::NotYetValid);
    }
    if now_ms.saturating_sub(CLOCK_SKEW_MS) >= expires_at_ms {
        return Err(TokenError::Expired);
    }

    Ok(SessionClaims {
        uid: uid.to_owned(),
        session_id: session_id.to_owned(),
        issued_at_ms,
        expires_at_ms,
    })
}

/// Turns raw entropy into the refresh token handed to the client and the
/// digest stored in D1. The caller supplies the bytes so this stays pure and
/// the randomness source is the caller's problem — on wasm that is
/// `getrandom`, which worker-rs already uses.
pub fn refresh_token_from_entropy(bytes: &[u8]) -> (String, String) {
    let token = base64url(bytes);
    let digest = refresh_token_digest(&token);
    (token, digest)
}

/// What is stored. Never store the token itself.
pub fn refresh_token_digest(token: &str) -> String {
    sha256_hex(token)
}

/// Whether a presented refresh token is well formed, checked before touching
/// the database so a malformed value costs nothing.
pub fn is_refresh_token(value: &str) -> bool {
    let expected = base64url(&[0u8; REFRESH_TOKEN_BYTES]).len();
    value.len() == expected
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn sign(signing_input: &str, secret: &str) -> String {
    // hmac_sha256_hex returns hex; base64url of the hex keeps the token
    // URL-safe without another dependency, and the comparison is
    // constant-time either way.
    base64url(hmac_sha256_hex(secret, signing_input).as_bytes())
}

fn decode_segment(segment: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(segment)
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "test-secret-value";
    const NOW: i64 = 1_700_000_000_000;

    #[test]
    fn round_trips_a_token() {
        let token = issue_access_token("usr_a", "sess_1", NOW, ACCESS_TOKEN_TTL_MS, SECRET);
        let claims = verify_access_token(&token, NOW, SECRET, None).expect("verifies");
        assert_eq!(claims.uid, "usr_a");
        assert_eq!(claims.session_id, "sess_1");
        assert_eq!(claims.expires_at_ms, NOW + ACCESS_TOKEN_TTL_MS);
    }

    #[test]
    fn rejects_a_token_signed_with_another_secret() {
        let token = issue_access_token("usr_a", "sess_1", NOW, ACCESS_TOKEN_TTL_MS, "other");
        assert_eq!(
            verify_access_token(&token, NOW, SECRET, None),
            Err(TokenError::BadSignature)
        );
    }

    #[test]
    fn rejects_a_tampered_payload() {
        let token = issue_access_token("usr_a", "sess_1", NOW, ACCESS_TOKEN_TTL_MS, SECRET);
        let mut parts: Vec<&str> = token.split('.').collect();
        let forged = base64url(
            json!({"sub": "usr_victim", "sid": "sess_1", "iat": NOW, "exp": NOW + 1})
                .to_string()
                .as_bytes(),
        );
        parts[1] = &forged;
        assert_eq!(
            verify_access_token(&parts.join("."), NOW, SECRET, None),
            Err(TokenError::BadSignature)
        );
    }

    #[test]
    fn refuses_to_read_alg_from_the_token() {
        // The `none` algorithm and HS256/RS256 confusion both start with the
        // verifier trusting the header. This one does not have a header path.
        let body = base64url(
            json!({"sub": "usr_a", "sid": "s", "iat": NOW, "exp": NOW + 60_000})
                .to_string()
                .as_bytes(),
        );
        let header = base64url(br#"{"alg":"none","typ":"JWT"}"#);
        assert_eq!(
            verify_access_token(&format!("{header}.{body}."), NOW, SECRET, None),
            Err(TokenError::Malformed)
        );
    }

    #[test]
    fn expires_and_allows_only_bounded_skew() {
        let token = issue_access_token("usr_a", "sess_1", NOW, 60_000, SECRET);
        assert!(verify_access_token(&token, NOW + 59_000, SECRET, None).is_ok());
        // Inside the skew window the token still verifies.
        assert!(
            verify_access_token(&token, NOW + 60_000 + CLOCK_SKEW_MS - 1, SECRET, None).is_ok()
        );
        assert_eq!(
            verify_access_token(&token, NOW + 60_000 + CLOCK_SKEW_MS, SECRET, None),
            Err(TokenError::Expired)
        );
    }

    #[test]
    fn rejects_a_token_from_the_future_beyond_skew() {
        let token = issue_access_token("usr_a", "sess_1", NOW, ACCESS_TOKEN_TTL_MS, SECRET);
        assert_eq!(
            verify_access_token(&token, NOW - CLOCK_SKEW_MS - 1, SECRET, None),
            Err(TokenError::NotYetValid)
        );
    }

    #[test]
    fn accepts_the_previous_secret_so_rotation_does_not_sign_everyone_out() {
        let token = issue_access_token("usr_a", "sess_1", NOW, ACCESS_TOKEN_TTL_MS, "old-secret");
        assert!(verify_access_token(&token, NOW, "new-secret", Some("old-secret")).is_ok());
        assert_eq!(
            verify_access_token(&token, NOW, "new-secret", Some("other-old")),
            Err(TokenError::BadSignature)
        );
    }

    #[test]
    fn rejects_malformed_shapes() {
        for bad in [
            "",
            "a",
            "a.b",
            "a.b.c.d",
            "...",
            &format!("{HEADER_B64}.!!!.x"),
        ] {
            assert!(
                verify_access_token(bad, NOW, SECRET, None).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn rejects_a_token_with_no_subject() {
        let body = base64url(
            json!({"sub": "", "sid": "s", "iat": NOW, "exp": NOW + 60_000})
                .to_string()
                .as_bytes(),
        );
        let input = format!("{HEADER_B64}.{body}");
        let token = format!("{input}.{}", sign(&input, SECRET));
        assert_eq!(
            verify_access_token(&token, NOW, SECRET, None),
            Err(TokenError::Malformed)
        );
    }

    #[test]
    fn refresh_tokens_store_only_a_digest() {
        let (token, digest) = refresh_token_from_entropy(&[7u8; REFRESH_TOKEN_BYTES]);
        assert!(is_refresh_token(&token));
        assert_ne!(token, digest);
        assert_eq!(digest, refresh_token_digest(&token));
        assert!(!digest.contains(&token));
    }

    #[test]
    fn refresh_token_shape_is_checked_before_the_database() {
        let (token, _) = refresh_token_from_entropy(&[1u8; REFRESH_TOKEN_BYTES]);
        assert!(is_refresh_token(&token));
        assert!(!is_refresh_token(""));
        assert!(!is_refresh_token("short"));
        assert!(!is_refresh_token(&format!("{token}x")));
        assert!(!is_refresh_token(&"!".repeat(token.len())));
    }

    #[test]
    fn different_entropy_gives_different_tokens() {
        let (a, da) = refresh_token_from_entropy(&[1u8; REFRESH_TOKEN_BYTES]);
        let (b, db) = refresh_token_from_entropy(&[2u8; REFRESH_TOKEN_BYTES]);
        assert_ne!(a, b);
        assert_ne!(da, db);
    }
}
