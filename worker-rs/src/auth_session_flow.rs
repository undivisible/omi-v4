//! Pure request/credential decisions for Worker-issued auth sessions.
//!
//! HTTP, D1, rate limiting, and random-byte acquisition stay in wasm glue.

use serde::Serialize;

use crate::{
    auth,
    session_token::{
        is_refresh_token, issue_access_token, refresh_token_from_entropy, ACCESS_TOKEN_TTL_MS,
        REFRESH_TOKEN_BYTES,
    },
};

/// Credentials returned by channel exchange and refresh. The refresh hash is
/// internal-only and must be stored by the D1 handler instead of serialized.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
    pub uid: String,
    #[serde(skip_serializing)]
    pub refresh_hash: String,
}

/// Request validation result for the refresh endpoint. `Reject` must map to
/// the same opaque 401 as a missing/revoked session, without querying D1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshInput {
    Reject,
    Lookup { refresh_hash: String },
}

/// The route is inert unless both migration controls are present. This keeps
/// Firebase as the fallback credential path during staged rollout.
pub fn exchange_enabled(dual_mode: bool, secret: Option<&str>) -> bool {
    auth::worker_auth_enabled(dual_mode, secret)
}

/// Makes an HTTP-safe token response and its storage-only refresh digest.
pub fn mint_response(
    uid: &str,
    session_id: &str,
    now_ms: i64,
    secret: &str,
    refresh_entropy: &[u8],
) -> Result<TokenResponse, ()> {
    if uid.is_empty()
        || session_id.is_empty()
        || secret.is_empty()
        || refresh_entropy.len() != REFRESH_TOKEN_BYTES
    {
        return Err(());
    }
    let (refresh_token, refresh_hash) = refresh_token_from_entropy(refresh_entropy);
    Ok(TokenResponse {
        access_token: issue_access_token(uid, session_id, now_ms, ACCESS_TOKEN_TTL_MS, secret),
        refresh_token,
        expires_at: now_ms.saturating_add(ACCESS_TOKEN_TTL_MS),
        uid: uid.to_owned(),
        refresh_hash,
    })
}

/// Reject malformed input before a storage lookup.
pub fn refresh_input(value: &str) -> RefreshInput {
    if is_refresh_token(value) {
        RefreshInput::Lookup {
            refresh_hash: crate::session_token::refresh_token_digest(value),
        }
    } else {
        RefreshInput::Reject
    }
}

#[cfg(test)]
mod tests {
    use super::{exchange_enabled, mint_response, refresh_input, RefreshInput};
    use crate::session_token::{refresh_token_digest, verify_access_token, ACCESS_TOKEN_TTL_MS};

    const NOW: i64 = 1_700_000_000_000;
    const SECRET: &str = "worker-test-secret";

    #[test]
    fn exchange_is_disabled_without_dual_mode_and_secret() {
        assert!(!exchange_enabled(false, Some(SECRET)));
        assert!(!exchange_enabled(true, None));
        assert!(!exchange_enabled(true, Some("")));
        assert!(exchange_enabled(true, Some(SECRET)));
    }

    #[test]
    fn token_response_preserves_the_existing_firebase_uid() {
        let response = mint_response("firebase-existing-uid", "session-1", NOW, SECRET, &[7; 32])
            .expect("valid entropy");

        assert_eq!(response.uid, "firebase-existing-uid");
        assert_eq!(response.expires_at, NOW + ACCESS_TOKEN_TTL_MS);
        assert_eq!(
            verify_access_token(&response.access_token, NOW, SECRET, None)
                .expect("access token verifies")
                .uid,
            "firebase-existing-uid"
        );
        assert!(!response.refresh_token.is_empty());
        assert!(!response.refresh_hash.is_empty());
    }

    #[test]
    fn malformed_refresh_rejects_before_store_lookup() {
        assert_eq!(refresh_input("not-a-token"), RefreshInput::Reject);
        assert_eq!(
            refresh_input(&"A".repeat(43)),
            RefreshInput::Lookup {
                refresh_hash: refresh_token_digest(&"A".repeat(43))
            }
        );
    }
}
