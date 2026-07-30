//! Pure request/credential decisions for Worker-issued auth sessions.
//!
//! HTTP, D1, rate limiting, and random-byte acquisition stay in wasm glue.

use serde::Serialize;

use crate::{
    auth,
    session_token::{
        is_refresh_token, issue_access_token, refresh_token_from_entropy, ACCESS_TOKEN_TTL_MS,
        REFRESH_TOKEN_BYTES, REFRESH_TOKEN_TTL_MS,
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

/// The storage-only values for a newly issued session. This deliberately has
/// no refresh token field: handlers must persist the digest, never the bearer
/// credential returned to the client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionWrite {
    pub id: String,
    pub uid: String,
    pub refresh_hash: String,
    pub origin: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub rotated_from: Option<String>,
}

/// Builds the D1 record for an issued credential. `rotated_from` is present
/// only on refresh, allowing the old session to be revoked in the same batch.
pub fn session_write(
    session_id: &str,
    rotated_from: &str,
    origin: &str,
    now_ms: i64,
    response: &TokenResponse,
) -> SessionWrite {
    SessionWrite {
        id: session_id.to_owned(),
        uid: response.uid.clone(),
        refresh_hash: response.refresh_hash.clone(),
        origin: origin.to_owned(),
        created_at: now_ms,
        expires_at: now_ms.saturating_add(REFRESH_TOKEN_TTL_MS),
        rotated_from: (!rotated_from.is_empty()).then(|| rotated_from.to_owned()),
    }
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

/// Returns the one Worker session an access token may sign out. Firebase
/// bearers cannot pass this check: only a Worker token with a valid signature
/// and an enabled dual-mode gate carries a session id.
pub fn worker_signout_session_id(
    token: &str,
    now_ms: i64,
    dual_mode: bool,
    secret: Option<&str>,
    previous_secret: Option<&str>,
) -> Option<String> {
    let secret = exchange_enabled(dual_mode, secret).then_some(secret?)?;
    crate::session_token::verify_access_token(token, now_ms, secret, previous_secret)
        .ok()
        .map(|claims| claims.session_id)
}

/// Creates the storage record for a Firebase-to-Worker credential upgrade.
/// The caller supplies the already-verified Firebase UID; no identity mapping
/// or account allocation occurs in this credential-only transition.
pub fn firebase_upgrade_write(
    session_id: &str,
    now_ms: i64,
    response: &TokenResponse,
) -> SessionWrite {
    session_write(session_id, "", "firebase_upgrade", now_ms, response)
}

/// Makes an HTTP-safe token response and its storage-only refresh digest.
pub fn mint_response(
    uid: &str,
    session_id: &str,
    now_ms: i64,
    secret: &str,
    refresh_entropy: &[u8],
) -> Option<TokenResponse> {
    if uid.is_empty()
        || session_id.is_empty()
        || secret.is_empty()
        || refresh_entropy.len() != REFRESH_TOKEN_BYTES
    {
        return None;
    }
    let (refresh_token, refresh_hash) = refresh_token_from_entropy(refresh_entropy);
    Some(TokenResponse {
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
    use super::{
        exchange_enabled, firebase_upgrade_write, mint_response, refresh_input, session_write,
        worker_signout_session_id, RefreshInput,
    };
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

    #[test]
    fn channel_session_write_keeps_only_a_refresh_digest_and_preserves_uid_on_rotation() {
        let response = mint_response(
            "firebase-existing-uid",
            "session-new",
            NOW,
            SECRET,
            &[9; 32],
        )
        .expect("valid entropy");
        let write = session_write("session-new", "session-old", "channel", NOW, &response);

        assert_eq!(write.id, "session-new");
        assert_eq!(write.uid, "firebase-existing-uid");
        assert_eq!(write.refresh_hash, response.refresh_hash);
        assert_eq!(write.origin, "channel");
        assert_eq!(write.rotated_from.as_deref(), Some("session-old"));
        assert_eq!(
            write.expires_at,
            NOW + crate::session_token::REFRESH_TOKEN_TTL_MS
        );
    }

    #[test]
    fn signout_accepts_only_an_enabled_valid_worker_access_token_for_its_session() {
        let response = mint_response("firebase-uid", "session-to-revoke", NOW, SECRET, &[3; 32])
            .expect("valid credentials");

        assert_eq!(
            worker_signout_session_id(&response.access_token, NOW, true, Some(SECRET), None),
            Some("session-to-revoke".to_string())
        );
        assert_eq!(
            worker_signout_session_id("firebase.bearer.token", NOW, true, Some(SECRET), None),
            None
        );
        assert_eq!(
            worker_signout_session_id(&response.access_token, NOW, false, Some(SECRET), None),
            None
        );
        assert_eq!(
            worker_signout_session_id(&response.access_token, NOW, true, None, None),
            None
        );
    }

    #[test]
    fn firebase_upgrade_write_keeps_the_firebase_uid_and_only_refresh_digest() {
        let response = mint_response(
            "firebase-existing-uid",
            "upgrade-session",
            NOW,
            SECRET,
            &[5; 32],
        )
        .expect("valid credentials");
        let write = firebase_upgrade_write("upgrade-session", NOW, &response);

        assert_eq!(write.id, "upgrade-session");
        assert_eq!(write.uid, "firebase-existing-uid");
        assert_eq!(write.origin, "firebase_upgrade");
        assert_eq!(write.refresh_hash, response.refresh_hash);
        assert_ne!(write.refresh_hash, response.refresh_token);
        assert_eq!(write.rotated_from, None);
    }
}
